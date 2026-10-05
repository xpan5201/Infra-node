#!/usr/bin/env bash

UPDATE_STAGING_DIR=''
UPDATE_PREVIOUS_DIR=''
UPDATE_SWAP_COMPLETE=0
# Set by update_stage_source/update_copy_local_tree, read by the install commands.
# shellcheck disable=SC2034
UPDATE_STAGED_COMMIT=''
UPDATE_LINKS_CAPTURED=0
UPDATE_INFRA_LINK_STATE=missing
UPDATE_INFRA_LINK_TARGET=''
UPDATE_PVF_LINK_STATE=missing
UPDATE_PVF_LINK_TARGET=''
UPDATE_FINALIZING=0
# Set by bin/infra-node from the self-update flags. Kept out of the positional
# argument list so `cmd_self_update [REF] [SHA]` keeps its original shape.
SELF_UPDATE_CHANNEL=''          # '' means "use INFRA_UPDATE_CHANNEL"
SELF_UPDATE_APPLY=0             # 1 = re-run deploy after a successful update
SELF_UPDATE_ALLOW_DOWNGRADE=0   # 1 = permit moving to a lower version
# Read by bin/infra-node's argument parser, never from this file.
# shellcheck disable=SC2034
SELF_UPDATE_CHECK=0             # 1 = report only, install nothing

update_git_with_timeout() {
  local seconds="$1"; shift
  if ! command -v timeout >/dev/null 2>&1; then core_log ERROR 'timeout missing'; return 127; fi
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=10 -oConnectionAttempts=1' \
    timeout --foreground "$seconds" git "$@"
}

update_check_error() {
  core_log ERROR "repository preflight failed: $*"
  ui_error "安装前检查失败：$*"
  return 1
}

update_tree_has_only_regular_entries() {
  local dir="$1" entry
  while IFS= read -r -d '' entry; do
    if [[ ! -f $entry && ! -d $entry && ! -L $entry ]]; then
      update_check_error "包含非常规文件：${entry#"$dir"/}"
      return 1
    fi
  done < <(find "$dir" -path "$dir/.git" -prune -o -print0)
}

update_validate_symlinks() {
  local dir="$1" link resolved
  while IFS= read -r -d '' link; do
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
    if [[ -z $resolved || ( $resolved != "$dir" && $resolved != "$dir"/* ) ]]; then
      update_check_error "符号链接越界或损坏：${link#"$dir"/}"
      return 1
    fi
  done < <(find "$dir" -path "$dir/.git" -prune -o -type l -print0)
}

update_normalize_entrypoint_modes() {
  local dir="$1" path
  # GitHub Web uploads and some ZIP extractors do not preserve executable bits.
  # Only fixed, known entrypoints are normalized; arbitrary files are never chmodded.
  for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do
    if [[ ! -f $dir/$path || -L $dir/$path ]]; then update_check_error "入口文件缺失：$path"; return 1; fi
    if ! chmod 0755 "$dir/$path"; then update_check_error "无法设置入口权限：$path"; return 1; fi
  done
}

update_run_smoke() {
  local dir="$1" safe_path sandbox uid gid rc=0 output
  local -a passthrough=()
  safe_path='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  # Forward the platform skip-guards when a caller set them. CI sets none of these,
  # so the assertions always run there; they exist only so the suite can run on an
  # environment without symlinks or POSIX permission bits.
  local _flag
  for _flag in INFRA_SMOKE_SKIP_SYMLINKS INFRA_SMOKE_SKIP_MODES INFRA_SMOKE_SKIP_SYNTAX; do
    [[ -n ${!_flag:-} ]] && passthrough+=("$_flag=${!_flag}")
  done
  output="$(mktemp "${TMPDIR:-/tmp}/infra-node-smoke-output.XXXXXX")"; core_register_tmp "$output"
  if [[ $(id -u) -eq 0 ]]; then
    if ! command -v setpriv >/dev/null 2>&1; then update_check_error 'setpriv 缺失，拒绝以 root 直接执行仓库测试'; return 1; fi
    if ! id nobody >/dev/null 2>&1; then update_check_error 'nobody 账户不存在'; return 1; fi
    sandbox="$(mktemp -d "${TMPDIR:-/tmp}/infra-node-smoke.XXXXXX")"; core_register_tmp "$sandbox"
    install -d -m 0755 "$sandbox/tree"; cp -a -- "$dir/." "$sandbox/tree/"
    uid="$(id -u nobody)"; gid="$(id -g nobody)"; chown -R "$uid:$gid" "$sandbox"
    setpriv --reuid="$uid" --regid="$gid" --clear-groups --no-new-privs \
      env -i PATH="$safe_path" HOME="$sandbox" TMPDIR="$sandbox" XDG_CONFIG_HOME="$sandbox" SHELL=/bin/bash LANG=C.UTF-8 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null INFRA_TEST_MODE=1 "${passthrough[@]}" \
      timeout 90 bash "$sandbox/tree/tests/smoke.sh" >"$output" 2>&1 || rc=$?
    rm -rf -- "$sandbox"; core_unregister_tmp "$sandbox"
  else
    env -i PATH="$safe_path" HOME="${TMPDIR:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" XDG_CONFIG_HOME="${TMPDIR:-/tmp}" SHELL=/bin/bash LANG=C.UTF-8 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null INFRA_TEST_MODE=1 "${passthrough[@]}" \
      timeout 90 bash "$dir/tests/smoke.sh" >"$output" 2>&1 || rc=$?
  fi
  if ((rc != 0)); then cat "$output" >>"$CORE_LOG_FILE" 2>/dev/null || true; ui_error 'Smoke Test 未通过：'; sed -n '1,40p' "$output" >&2; rm -f -- "$output"; core_unregister_tmp "$output"; return "$rc"; fi
  cat "$output" >>"$CORE_LOG_FILE" 2>/dev/null || true
  rm -f -- "$output"; core_unregister_tmp "$output"
}

update_preflight_tree() {
  local dir="$1" file version
  if [[ ! -d $dir || -L $dir ]]; then update_check_error '源码目录无效'; return 1; fi
  for file in VERSION bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh README.md LICENSE config/defaults.env; do
    if [[ ! -f $dir/$file || -L $dir/$file ]]; then update_check_error "必要文件缺失或类型错误：$file"; return 1; fi
  done
  version="$(tr -d '\r\n' <"$dir/VERSION")"
  if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?$ ]]; then update_check_error "VERSION 格式无效：$version"; return 1; fi
  update_tree_has_only_regular_entries "$dir" || return
  update_validate_symlinks "$dir" || return
  while IFS= read -r -d '' file; do
    if ! bash -n "$file"; then update_check_error "Bash 语法错误：${file#"$dir"/}"; return 1; fi
  done < <(find "$dir" -path "$dir/.git" -prune -o -type f -name '*.sh' -print0)
  if ! bash -n "$dir/bin/infra-node"; then update_check_error 'bin/infra-node 语法错误'; return 1; fi
  if ! bash -n "$dir/config/defaults.env"; then update_check_error 'config/defaults.env 语法错误'; return 1; fi
  update_normalize_entrypoint_modes "$dir" || return
  update_run_smoke "$dir" || return
}

# Compatibility for third-party wrappers that sourced older releases.
update_verify_tree() { update_preflight_tree "$@"; }

update_clone_ref() {
  local url="$1" ref="$2" destination="$3"
  core_safe_repo_url "$url" || return 2; core_safe_ref "$ref" || return 2
  rm -rf -- "$destination"
  if update_git_with_timeout "$INFRA_GIT_TIMEOUT" clone --quiet --depth 1 --single-branch --branch "$ref" -- "$url" "$destination" >>"$CORE_LOG_FILE" 2>&1; then return 0; fi
  rm -rf -- "$destination"
  # shellcheck disable=SC2129  # two separate appends, not a redirect group
  update_git_with_timeout "$INFRA_GIT_TIMEOUT" clone --quiet --no-checkout --depth 1 -- "$url" "$destination" >>"$CORE_LOG_FILE" 2>&1
  update_git_with_timeout "$INFRA_GIT_TIMEOUT" -C "$destination" fetch --quiet --depth 1 origin "$ref" >>"$CORE_LOG_FILE" 2>&1
  update_git_with_timeout "$INFRA_GIT_TIMEOUT" -C "$destination" checkout --quiet --detach FETCH_HEAD >>"$CORE_LOG_FILE" 2>&1
}

# Why the local checkout was not used as the install source. Falling back to a
# network clone is legitimate, but doing it *silently* means the operator gets a
# different tree than the one they pointed at with no way to notice — which is
# exactly how an end-to-end run once installed the wrong commit (root could not
# read the repository over /mnt/c and nothing said so).
update_local_source_reason() {
  local local_source="$1" url="$2" ref="$3" head ref_commit origin dirty
  local -a why=()
  if [[ ! -d $local_source/.git ]]; then
    printf '%s\n' '不是 Git 检出'
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    printf '%s\n' '系统里没有 git'
    return 0
  fi
  head="$(git -C "$local_source" rev-parse HEAD 2>/dev/null || true)"
  if [[ -z $head ]]; then
    printf '%s\n' "git 无法读取该仓库（属主或权限问题；可执行 git config --global --add safe.directory '$local_source' 解决）"
    return 0
  fi
  ref_commit="$(git -C "$local_source" rev-parse "${ref}^{commit}" 2>/dev/null || true)"
  origin="$(git -C "$local_source" remote get-url origin 2>/dev/null || true)"
  dirty="$(git -C "$local_source" status --porcelain --untracked-files=no 2>/dev/null || true)"
  if [[ -z $ref_commit ]]; then why+=("本地没有 ref ${ref}"); fi
  if [[ -n $ref_commit && $head != "$ref_commit" ]]; then why+=("HEAD ${head:0:12} 不是 ${ref} 的提交 ${ref_commit:0:12}"); fi
  if [[ -n $origin && $origin != "$url" ]]; then why+=("origin 是 ${origin}，而记录的是 ${url}"); fi
  if [[ -n $dirty ]]; then why+=('工作区有未提交改动'); fi
  if ((${#why[@]} == 0)); then
    printf '%s\n' '未满足本地快路径条件'
  else
    printf '%s\n' "${why[*]}"
  fi
}

update_stage_source() {
  local url="$1" ref="$2" destination="$3" local_source="${4:-}" head ref_commit origin dirty
  UPDATE_STAGED_COMMIT=''
  if [[ -n $local_source && -d $local_source/.git ]]; then
    head="$(git -C "$local_source" rev-parse HEAD 2>/dev/null || true)"
    ref_commit="$(git -C "$local_source" rev-parse "${ref}^{commit}" 2>/dev/null || true)"
    origin="$(git -C "$local_source" remote get-url origin 2>/dev/null || true)"
    dirty="$(git -C "$local_source" status --porcelain --untracked-files=no 2>/dev/null || true)"
    if [[ -n $head && $head == "$ref_commit" && $origin == "$url" && -z $dirty ]]; then
      rm -rf -- "$destination"; install -d -m 0755 "$destination"
      if git -C "$local_source" archive --format=tar HEAD | tar -xf - -C "$destination"; then
        UPDATE_STAGED_COMMIT="$head"; return 0
      fi
      rm -rf -- "$destination"
    fi
    ui_warn "未从本地检出安装：$(update_local_source_reason "$local_source" "$url" "$ref")。"
    ui_warn "改为从 ${url} 拉取 ${ref}；如需装本地这棵树，请先处理上面的原因。"
  fi
  update_clone_ref "$url" "$ref" "$destination" || return
  UPDATE_STAGED_COMMIT="$(git -C "$destination" rev-parse HEAD)" || return
  rm -rf -- "$destination/.git"
}

update_prepare_command_links() {
  local path target
  UPDATE_INFRA_LINK_STATE=missing; UPDATE_INFRA_LINK_TARGET=''; UPDATE_PVF_LINK_STATE=missing; UPDATE_PVF_LINK_TARGET=''
  for path in "$INFRA_COMMAND_DIR/infra-node" "$INFRA_COMMAND_DIR/pvf"; do
    if [[ -e $path || -L $path ]]; then
      if [[ ! -L $path ]]; then core_die "命令路径被普通文件占用：$path"; return 1; fi
      target="$(readlink "$path")"
      if [[ $path == */infra-node ]]; then UPDATE_INFRA_LINK_STATE=symlink; UPDATE_INFRA_LINK_TARGET="$target"; else UPDATE_PVF_LINK_STATE=symlink; UPDATE_PVF_LINK_TARGET="$target"; fi
    fi
  done
  UPDATE_LINKS_CAPTURED=1
}

update_atomic_symlink() { local target="$1" link="$2" dir tmp; dir="$(dirname "$link")"; mkdir -p -- "$dir"; tmp="${dir}/.infra-node-link.$$.$RANDOM"; ln -s -- "$target" "$tmp"; mv -Tf -- "$tmp" "$link"; }
update_apply_command_links() { update_atomic_symlink "$INFRA_INSTALL_DIR/bin/infra-node" "$INFRA_COMMAND_DIR/infra-node"; update_atomic_symlink "$INFRA_COMMAND_DIR/infra-node" "$INFRA_COMMAND_DIR/pvf"; }
update_restore_command_links() {
  ((UPDATE_LINKS_CAPTURED==1)) || return 0
  if [[ $UPDATE_INFRA_LINK_STATE == symlink ]]; then
    update_atomic_symlink "$UPDATE_INFRA_LINK_TARGET" "$INFRA_COMMAND_DIR/infra-node"
  else
    rm -f -- "$INFRA_COMMAND_DIR/infra-node"
  fi
  if [[ $UPDATE_PVF_LINK_STATE == symlink ]]; then
    update_atomic_symlink "$UPDATE_PVF_LINK_TARGET" "$INFRA_COMMAND_DIR/pvf"
  else
    rm -f -- "$INFRA_COMMAND_DIR/pvf"
  fi
}

update_write_repo_metadata() {
  local url="$1" ref="$2" commit="$3" channel=git
  [[ -n $commit ]] || channel=zip
  mkdir -p -- "$INFRA_ETC_DIR"; txn_begin 'repository metadata'
  txn_write_file "$INFRA_ETC_DIR/repo.env" 0644 <<EOF_META
URL=$url
REF=$ref
COMMIT=$commit
CHANNEL=$channel
INSTALLED_AT=$(core_now)
EOF_META
}

update_repo_value() { local key="$1" fallback="$2"; if [[ -r $INFRA_ETC_DIR/repo.env ]]; then awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$INFRA_ETC_DIR/repo.env"; else printf '%s\n' "$fallback"; fi; }

# --- version comparison (pure, testable) --------------------------------------

# Fixed-width key for the release triple, so two versions compare with a plain
# string compare. A pre-release suffix ("1.6.4-rc1", "1.6.4.rc1") collapses onto
# the release it leads to: erring towards "not a downgrade" is deliberate, since
# the guard exists to catch accidents, not to adjudicate pre-release ordering.
update_version_key() {
  local v="${1:-}"
  v="${v#v}"
  if [[ $v =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    printf '%05d%05d%05d\n' \
      "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
    return 0
  fi
  return 1
}

# Prints -1 (a<b), 0 (equal), 1 (a>b), or ? when either side cannot be parsed.
update_version_cmp() {
  local ka kb
  ka="$(update_version_key "${1:-}")" || { printf '?\n'; return 0; }
  kb="$(update_version_key "${2:-}")" || { printf '?\n'; return 0; }
  if [[ $ka == "$kb" ]]; then
    printf '0\n'
  elif [[ $ka < $kb ]]; then
    printf '%s\n' -1
  else
    printf '1\n'
  fi
}

# --- recorded vs installed state ----------------------------------------------

update_installed_version() {
  [[ -r $INFRA_INSTALL_DIR/VERSION ]] || return 1
  tr -d '\r\n' <"$INFRA_INSTALL_DIR/VERSION"
}
update_repo_url() { update_repo_value URL "$INFRA_REPO_URL"; }
update_repo_ref() { update_repo_value REF "$INFRA_REPO_REF"; }
update_repo_commit() { update_repo_value COMMIT ''; }

# Version that generated the currently applied host configuration. deploy.env is
# the only witness: after self-update the program is newer than its own output,
# and nothing else notices that new tuning keys never took effect.
update_deployed_version() {
  awk -F= '$1=="VERSION"{sub(/^[^=]*=/,"");print;exit}' "$INFRA_STATE_DIR/deploy.env" 2>/dev/null || true
}
update_deployed_profile() {
  awk -F= '$1=="PROFILE"{sub(/^[^=]*=/,"");print;exit}' "$INFRA_STATE_DIR/deploy.env" 2>/dev/null || true
}

# --- update channel -----------------------------------------------------------

# Newest release tag. `--refs` drops the peeled "^{}" lines that annotated tags
# produce, so this stays one line per tag. Returns 1 when nothing usable is
# reachable, which callers must treat as "fall back", never as "abort".
update_latest_tag() {
  local url="$1" out tag
  out="$(update_git_with_timeout "$INFRA_GIT_TIMEOUT" ls-remote --tags --refs -- "$url" 2>/dev/null || true)"
  [[ -n $out ]] || return 1
  tag="$(printf '%s\n' "$out" \
    | awk '$2 ~ /^refs\/tags\// { sub(/^refs\/tags\//, "", $2); print $2 }' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n 1 || true)"
  [[ -n $tag ]] || return 1
  printf '%s\n' "$tag"
}

# Which ref self-update should target:
#   explicit REF argument  >  channel=tag (latest tag)  >  recorded REF
update_resolve_ref() {
  local explicit="${1:-}" channel="${2:-}" url="$3" fallback="$4" tag
  if [[ -n $explicit ]]; then printf '%s\n' "$explicit"; return 0; fi
  case "$channel" in
    tag)
      if tag="$(update_latest_tag "$url")"; then printf '%s\n' "$tag"; return 0; fi
      ui_warn "远端没有可用的发行 tag，回退到 ${fallback}。"
      ;;
    main|ref) ;;
    *) core_die "未知更新通道：${channel}（可用 tag / main）"; return 1 ;;
  esac
  printf '%s\n' "$fallback"
}

# --- config drift --------------------------------------------------------------

# The applied host configuration (sysctl / journald / proxy drop-ins) is generated
# by whatever version was installed when `deploy` last ran. Nothing re-runs deploy
# on update, so a new version's new keys silently do nothing until it does.
update_report_config_drift() {
  local deployed installed
  installed="$(update_installed_version || true)"
  deployed="$(update_deployed_version)"
  if [[ -z $deployed ]]; then
    ui_warn '还未部署过主机配置；运行 sudo infra-node deploy 后才会生效。'
    return 1
  fi
  if [[ $deployed != "$installed" ]]; then
    ui_warn "已应用的主机配置由 v${deployed} 生成，当前程序是 v${installed}。"
    ui_warn '新版本引入的主机参数在重新部署前不会生效：sudo infra-node deploy'
    return 1
  fi
  ui_ok "已应用的主机配置与当前程序版本一致（v${installed}）。"
  return 0
}

# --- rollback helpers ----------------------------------------------------------

update_backup_candidates() {
  local parent base
  parent="$(dirname "$INFRA_INSTALL_DIR")"
  base="$(basename "$INFRA_INSTALL_DIR")"
  find "$parent" -mindepth 1 -maxdepth 1 -type d -name "${base}.backup.*" -printf '%f\n' 2>/dev/null | sort -r || true
}

# Keep the outgoing repository metadata with the outgoing tree so a rollback can
# put /etc/infra-node/repo.env back in sync with the code it describes. Nothing
# else records it: update_write_repo_metadata runs after the directory swap.
update_snapshot_repo_metadata() {
  local dir="$1"
  [[ -r $INFRA_ETC_DIR/repo.env && -d $dir ]] || return 0
  install -m 0644 -- "$INFRA_ETC_DIR/repo.env" "$dir/.infra-node-repo.env" 2>/dev/null || true
}

update_failure_restore() {
  local had=0 failed
  [[ $- == *e* ]] && had=1; set +e
  if ((UPDATE_FINALIZING==1)) && [[ ${TXN_OUTCOME:-none} == committed ]]; then ((had==0)) || set -e; return 0; fi
  if ((UPDATE_SWAP_COMPLETE==1)); then
    if [[ -e $INFRA_INSTALL_DIR ]]; then failed="${INFRA_INSTALL_DIR}.failed.$(core_unique_stamp)"; mv -T -- "$INFRA_INSTALL_DIR" "$failed" || true; fi
    [[ -n $UPDATE_PREVIOUS_DIR && -e $UPDATE_PREVIOUS_DIR ]] && mv -T -- "$UPDATE_PREVIOUS_DIR" "$INFRA_INSTALL_DIR"
  fi
  update_restore_command_links || true
  [[ -n $UPDATE_STAGING_DIR ]] && rm -rf -- "$UPDATE_STAGING_DIR"
  ((had==0)) || set -e
}

update_prune_backups() { local parent="$1" base="$2" keep="${INFRA_BACKUP_KEEP:-5}" n=0 d; while IFS= read -r d; do n=$((n+1)); ((n<=keep)) || rm -rf -- "$d"; done < <(find "$parent" -maxdepth 1 -type d -name "${base}.backup.*" -print | sort -r); }


update_assert_install_target_safe() {
  if [[ -e $INFRA_INSTALL_DIR || -L $INFRA_INSTALL_DIR ]]; then
    if [[ ! -d $INFRA_INSTALL_DIR || -L $INFRA_INSTALL_DIR ]]; then core_die "安装路径不是普通目录：$INFRA_INSTALL_DIR"; return 1; fi
  fi
}

cmd_self_update() {
  local requested_ref="${1:-}" expected="${2:-}" url ref parent stamp new new_version old_version cmp channel
  core_require_root || return; core_acquire_lock || return; platform_detect_all || return; platform_require_free_space 220 || return; update_assert_install_target_safe || return
  url="$(update_repo_url)"
  if ! core_safe_repo_url "$url"; then core_die "记录的仓库地址无效：$url（检查 ${INFRA_ETC_DIR}/repo.env）"; return 1; fi
  channel="${SELF_UPDATE_CHANNEL:-${INFRA_UPDATE_CHANNEL:-main}}"
  ref="$(update_resolve_ref "$requested_ref" "$channel" "$url" "$(update_repo_ref)")" || return
  if ! core_safe_ref "$ref"; then core_die 'ref 无效'; return 1; fi
  if [[ -n $expected && ! $expected =~ ^[0-9a-fA-F]{40}$ ]]; then core_die '期望提交必须为 40 位 SHA'; return 1; fi
  old_version="$(update_installed_version || true)"
  parent="$(dirname "$INFRA_INSTALL_DIR")"; stamp="$(core_unique_stamp)"; UPDATE_STAGING_DIR="${INFRA_INSTALL_DIR}.staging.$stamp"; UPDATE_PREVIOUS_DIR="${INFRA_INSTALL_DIR}.backup.$stamp"
  core_register_failure_hook update_failure_restore
  core_run_step '拉取 Git 仓库' update_stage_source "$url" "$ref" "$UPDATE_STAGING_DIR"
  new="$UPDATE_STAGED_COMMIT"
  if [[ -n $expected && ${new,,} != "${expected,,}" ]]; then core_die '提交校验失败'; return 1; fi
  # Refuse a downgrade before the expensive preflight: the clone is already paid
  # for, the smoke run is not. The guard exists to catch accidents, so it needs an
  # explicit opt-out rather than being silently permissive.
  new_version="$(tr -d '\r\n' <"$UPDATE_STAGING_DIR/VERSION" 2>/dev/null || true)"
  if [[ ${SELF_UPDATE_ALLOW_DOWNGRADE:-0} -ne 1 && -n $old_version && -n $new_version ]]; then
    cmp="$(update_version_cmp "$new_version" "$old_version")"
    if [[ $cmp == -1 ]]; then
      core_die "目标版本 v${new_version} 低于当前 v${old_version}；确认要降级请加 --allow-downgrade。"
      return 1
    fi
  fi
  core_run_step '执行结构、语法、链接和 Smoke 检查' update_preflight_tree "$UPDATE_STAGING_DIR"
  update_prepare_command_links
  if [[ -e $INFRA_INSTALL_DIR ]]; then
    mv -T -- "$INFRA_INSTALL_DIR" "$UPDATE_PREVIOUS_DIR"
    update_snapshot_repo_metadata "$UPDATE_PREVIOUS_DIR"
    UPDATE_SWAP_COMPLETE=1
  fi
  mv -T -- "$UPDATE_STAGING_DIR" "$INFRA_INSTALL_DIR"; UPDATE_STAGING_DIR=''; UPDATE_SWAP_COMPLETE=1
  update_apply_command_links; update_write_repo_metadata "$url" "$ref" "$new"; "$INFRA_INSTALL_DIR/bin/infra-node" version >/dev/null
  UPDATE_FINALIZING=1; txn_commit; UPDATE_SWAP_COMPLETE=0; core_unregister_failure_hook update_failure_restore; UPDATE_FINALIZING=0
  update_prune_backups "$parent" "$(basename "$INFRA_INSTALL_DIR")"
  ui_ok "已更新到 v${new_version}（${new:0:12}，ref=${ref}）。"
  if [[ ${SELF_UPDATE_APPLY:-0} -eq 1 ]]; then
    ui_info '按 --apply 重新应用主机配置...'
    deploy_run "$(update_deployed_profile || true)" auto no auto no
  else
    # Advisory only: the update itself succeeded, so this must not change the exit
    # status of a command scripts may be running unattended.
    update_report_config_drift || true
  fi
}

cmd_self_check() {
  local requested_ref="${1:-}" url ref channel installed installed_commit staging remote_version remote_commit
  platform_detect_all || return
  url="$(update_repo_url)"
  if ! core_safe_repo_url "$url"; then core_die "记录的仓库地址无效：$url"; return 1; fi
  channel="${SELF_UPDATE_CHANNEL:-${INFRA_UPDATE_CHANNEL:-main}}"
  ref="$(update_resolve_ref "$requested_ref" "$channel" "$url" "$(update_repo_ref)")" || return
  if ! core_safe_ref "$ref"; then core_die 'ref 无效'; return 1; fi
  installed="$(update_installed_version || true)"
  installed_commit="$(update_repo_commit)"
  ui_section '更新检查'
  ui_kv '仓库' "$url"
  ui_kv '通道' "$channel"
  ui_kv '目标 ref' "$ref"
  ui_kv '已安装版本' "${installed:-未知}"
  ui_kv '已安装提交' "${installed_commit:-未记录（可能来自发行包）}"
  if [[ ! -d $INFRA_INSTALL_DIR ]]; then
    ui_warn "尚未安装到 ${INFRA_INSTALL_DIR}，无法与远端比较。"
    return 0
  fi
  staging="$(mktemp -d "${TMPDIR:-/tmp}/infra-node-check.XXXXXX")"; core_register_tmp "$staging"
  if ! update_clone_ref "$url" "$ref" "$staging/tree" >>"$CORE_LOG_FILE" 2>&1; then
    rm -rf -- "$staging"; core_unregister_tmp "$staging"
    ui_error "无法读取远端仓库（网络不通或 ref 不存在）：${ref}"
    return 1
  fi
  remote_version="$(tr -d '\r\n' <"$staging/tree/VERSION" 2>/dev/null || true)"
  remote_commit="$(git -C "$staging/tree" rev-parse HEAD 2>/dev/null || true)"
  rm -rf -- "$staging"; core_unregister_tmp "$staging"
  ui_kv '远端版本' "${remote_version:-未知}"
  ui_kv '远端提交' "${remote_commit:-未知}"
  case "$(update_version_cmp "$remote_version" "$installed")" in
    -1) ui_warn "远端版本更低（v${remote_version} < v${installed}）：self-update 会拒绝降级，除非加 --allow-downgrade。" ;;
    0)  if [[ -n $installed_commit && -n $remote_commit && $installed_commit != "$remote_commit" ]]; then
          ui_warn '版本号相同但提交不同；self-update 会切换到远端提交。'
        else
          ui_ok '与远端一致。'
        fi ;;
    1)  ui_warn "有新版本：v${installed:-?} → v${remote_version}。运行：sudo infra-node self-update" ;;
    *)  ui_warn '版本号无法解析，跳过新旧判断（提交比较仍有效）。' ;;
  esac
  update_report_config_drift || true
}

cmd_self_rollback() {
  local which="${1:-}" parent base stamp chosen='' c i=1
  local -a candidates=()
  core_require_root || return; core_acquire_lock || return; platform_detect_all || return; update_assert_install_target_safe || return
  parent="$(dirname "$INFRA_INSTALL_DIR")"; base="$(basename "$INFRA_INSTALL_DIR")"
  while IFS= read -r c; do [[ -n $c ]] && candidates+=("$c"); done < <(update_backup_candidates)
  if ((${#candidates[@]} == 0)); then
    ui_error "没有可回滚的备份（${parent}/${base}.backup.*）。"
    return 1
  fi
  ui_section '可回滚的版本（新 → 旧）'
  ui_kv '当前版本' "$(update_installed_version || echo 未知)"
  for c in "${candidates[@]}"; do
    printf '  %d) %s  v%s\n' "$i" "${c#"$base".backup.}" "$(tr -d '\r\n' <"$parent/$c/VERSION" 2>/dev/null || echo '?')"
    i=$((i+1))
  done
  if [[ -z $which ]]; then
    ui_info '指定其一即可回滚，例如：sudo infra-node self-rollback latest'
    return 0
  fi
  case "$which" in
    latest|1) chosen="${candidates[0]}" ;;
    [0-9]*)
      if ((10#$which >= 1 && 10#$which <= ${#candidates[@]})); then
        chosen="${candidates[$((10#$which - 1))]}"
      else
        core_die "序号越界：${which}（可选 1..${#candidates[@]}）"; return 1
      fi ;;
    *)
      for c in "${candidates[@]}"; do [[ $c == "$which" ]] && chosen="$c"; done
      if [[ -z $chosen ]]; then core_die "找不到备份：${which}"; return 1; fi ;;
  esac
  stamp="$(core_unique_stamp)"; UPDATE_PREVIOUS_DIR="${INFRA_INSTALL_DIR}.backup.${stamp}"
  core_register_failure_hook update_failure_restore
  update_prepare_command_links
  mv -T -- "$INFRA_INSTALL_DIR" "$UPDATE_PREVIOUS_DIR"; UPDATE_SWAP_COMPLETE=1
  mv -T -- "$parent/$chosen" "$INFRA_INSTALL_DIR"
  update_apply_command_links
  # Put the repository metadata back in step with the code, then drop the copy so
  # the install tree stays exactly what the preflight considers valid.
  if [[ -r $INFRA_INSTALL_DIR/.infra-node-repo.env ]]; then
    txn_begin 'rollback metadata'
    txn_write_file "$INFRA_ETC_DIR/repo.env" 0644 <"$INFRA_INSTALL_DIR/.infra-node-repo.env"
  else
    txn_begin 'rollback metadata'
  fi
  rm -f -- "$INFRA_INSTALL_DIR/.infra-node-repo.env"
  "$INFRA_INSTALL_DIR/bin/infra-node" version >/dev/null
  UPDATE_FINALIZING=1; txn_commit; UPDATE_SWAP_COMPLETE=0; core_unregister_failure_hook update_failure_restore; UPDATE_FINALIZING=0
  update_prune_backups "$parent" "$base"
  ui_ok "已回滚到 v$(update_installed_version || echo 未知)。"
  update_report_config_drift || true
}

update_copy_local_tree() {
  local source="$1" destination="$2"
  if [[ ! -d $source || -L $source ]]; then core_die '本地源码目录无效。'; return 1; fi
  update_tree_has_only_regular_entries "$source" || return
  update_validate_symlinks "$source" || return
  rm -rf -- "$destination"; install -d -m 0755 "$destination"
  tar -C "$source" --exclude='./.git' --exclude='./dist' --exclude='./.DS_Store' --no-xattrs --no-acls --no-selinux -cf - .     | tar -C "$destination" --no-same-owner --no-xattrs --no-acls --no-selinux -xf -
  UPDATE_STAGED_COMMIT="$(git -C "$source" rev-parse HEAD 2>/dev/null || true)"
}

update_install_from_source() {
  local source="$1" url="${2:-$INFRA_REPO_URL}" ref="${3:-$INFRA_REPO_REF}" parent stamp commit
  core_require_root || return; core_acquire_lock || return; platform_detect_all || return; platform_require_free_space 220 || return; update_assert_install_target_safe || return
  parent="$(dirname "$INFRA_INSTALL_DIR")"; stamp="$(core_unique_stamp)"
  UPDATE_STAGING_DIR="${INFRA_INSTALL_DIR}.staging.$stamp"; UPDATE_PREVIOUS_DIR="${INFRA_INSTALL_DIR}.backup.$stamp"
  core_register_failure_hook update_failure_restore
  if [[ -d $source/.git ]]; then
    core_run_step '准备仓库版本' update_stage_source "$url" "$ref" "$UPDATE_STAGING_DIR" "$source"
  else
    core_run_step '复制本地发行包' update_copy_local_tree "$source" "$UPDATE_STAGING_DIR"
  fi
  commit="$UPDATE_STAGED_COMMIT"
  [[ -n $commit ]] || ui_warn '此安装来自发行包，未记录 Git 提交；self-update 将无法按 SHA 锁定版本。'
  core_run_step '执行结构、语法、链接和 Smoke 检查' update_preflight_tree "$UPDATE_STAGING_DIR"
  update_prepare_command_links
  if [[ -e $INFRA_INSTALL_DIR ]]; then mv -T -- "$INFRA_INSTALL_DIR" "$UPDATE_PREVIOUS_DIR"; UPDATE_SWAP_COMPLETE=1; fi
  mv -T -- "$UPDATE_STAGING_DIR" "$INFRA_INSTALL_DIR"; UPDATE_STAGING_DIR=''; UPDATE_SWAP_COMPLETE=1
  update_apply_command_links
  update_write_repo_metadata "$url" "$ref" "$commit"
  "$INFRA_INSTALL_DIR/bin/infra-node" version >/dev/null
  UPDATE_FINALIZING=1; txn_commit; UPDATE_SWAP_COMPLETE=0; core_unregister_failure_hook update_failure_restore; UPDATE_FINALIZING=0
  update_prune_backups "$parent" "$(basename "$INFRA_INSTALL_DIR")"
  ui_ok "Infra-node v$(cat "$INFRA_INSTALL_DIR/VERSION") 已安装。"
}
