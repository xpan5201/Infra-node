#!/usr/bin/env bash

UPDATE_STAGING_DIR=''
UPDATE_PREVIOUS_DIR=''
UPDATE_SWAP_COMPLETE=0
UPDATE_STAGED_COMMIT=''
UPDATE_STAGED_FROM_LOCAL=0
UPDATE_LINKS_CAPTURED=0
UPDATE_INFRA_LINK_STATE=missing
UPDATE_INFRA_LINK_TARGET=''
UPDATE_PVF_LINK_STATE=missing
UPDATE_PVF_LINK_TARGET=''
UPDATE_FINALIZING=0

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
      update_check_error "包含非常规文件：${entry#$dir/}"
      return 1
    fi
  done < <(find "$dir" -path "$dir/.git" -prune -o -print0)
}

update_validate_symlinks() {
  local dir="$1" link resolved
  while IFS= read -r -d '' link; do
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
    if [[ -z $resolved || ( $resolved != "$dir" && $resolved != "$dir"/* ) ]]; then
      update_check_error "符号链接越界或损坏：${link#$dir/}"
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
  safe_path='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  output="$(mktemp "${TMPDIR:-/tmp}/infra-node-smoke-output.XXXXXX")"; core_register_tmp "$output"
  if [[ $(id -u) -eq 0 ]]; then
    if ! command -v setpriv >/dev/null 2>&1; then update_check_error 'setpriv 缺失，拒绝以 root 直接执行仓库测试'; return 1; fi
    if ! id nobody >/dev/null 2>&1; then update_check_error 'nobody 账户不存在'; return 1; fi
    sandbox="$(mktemp -d "${TMPDIR:-/tmp}/infra-node-smoke.XXXXXX")"; core_register_tmp "$sandbox"
    install -d -m 0755 "$sandbox/tree"; cp -a -- "$dir/." "$sandbox/tree/"
    uid="$(id -u nobody)"; gid="$(id -g nobody)"; chown -R "$uid:$gid" "$sandbox"
    setpriv --reuid="$uid" --regid="$gid" --clear-groups --no-new-privs \
      env -i PATH="$safe_path" HOME="$sandbox" TMPDIR="$sandbox" XDG_CONFIG_HOME="$sandbox" SHELL=/bin/bash LANG=C.UTF-8 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null INFRA_TEST_MODE=1 \
      timeout 90 bash "$sandbox/tree/tests/smoke.sh" >"$output" 2>&1 || rc=$?
    rm -rf -- "$sandbox"; core_unregister_tmp "$sandbox"
  else
    env -i PATH="$safe_path" HOME="${TMPDIR:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" XDG_CONFIG_HOME="${TMPDIR:-/tmp}" SHELL=/bin/bash LANG=C.UTF-8 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null INFRA_TEST_MODE=1 \
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
    if ! bash -n "$file"; then update_check_error "Bash 语法错误：${file#$dir/}"; return 1; fi
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
  update_git_with_timeout "$INFRA_GIT_TIMEOUT" clone --quiet --no-checkout --depth 1 -- "$url" "$destination" >>"$CORE_LOG_FILE" 2>&1
  update_git_with_timeout "$INFRA_GIT_TIMEOUT" -C "$destination" fetch --quiet --depth 1 origin "$ref" >>"$CORE_LOG_FILE" 2>&1
  update_git_with_timeout "$INFRA_GIT_TIMEOUT" -C "$destination" checkout --quiet --detach FETCH_HEAD >>"$CORE_LOG_FILE" 2>&1
}

update_stage_source() {
  local url="$1" ref="$2" destination="$3" local_source="${4:-}" head ref_commit origin dirty
  UPDATE_STAGED_COMMIT=''; UPDATE_STAGED_FROM_LOCAL=0
  if [[ -n $local_source && -d $local_source/.git ]]; then
    head="$(git -C "$local_source" rev-parse HEAD 2>/dev/null || true)"
    ref_commit="$(git -C "$local_source" rev-parse "${ref}^{commit}" 2>/dev/null || true)"
    origin="$(git -C "$local_source" remote get-url origin 2>/dev/null || true)"
    dirty="$(git -C "$local_source" status --porcelain --untracked-files=no 2>/dev/null || true)"
    if [[ -n $head && $head == "$ref_commit" && $origin == "$url" && -z $dirty ]]; then
      rm -rf -- "$destination"; install -d -m 0755 "$destination"
      if git -C "$local_source" archive --format=tar HEAD | tar -xf - -C "$destination"; then
        UPDATE_STAGED_COMMIT="$head"; UPDATE_STAGED_FROM_LOCAL=1; return 0
      fi
      rm -rf -- "$destination"
    fi
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
  [[ $UPDATE_INFRA_LINK_STATE == symlink ]] && update_atomic_symlink "$UPDATE_INFRA_LINK_TARGET" "$INFRA_COMMAND_DIR/infra-node" || rm -f -- "$INFRA_COMMAND_DIR/infra-node"
  [[ $UPDATE_PVF_LINK_STATE == symlink ]] && update_atomic_symlink "$UPDATE_PVF_LINK_TARGET" "$INFRA_COMMAND_DIR/pvf" || rm -f -- "$INFRA_COMMAND_DIR/pvf"
}

update_write_repo_metadata() {
  local url="$1" ref="$2" commit="$3"
  mkdir -p -- "$INFRA_ETC_DIR"; txn_begin 'repository metadata'
  txn_write_file "$INFRA_ETC_DIR/repo.env" 0644 <<EOF_META
URL=$url
REF=$ref
COMMIT=$commit
INSTALLED_AT=$(core_now)
EOF_META
}

update_repo_value() { local key="$1" fallback="$2"; if [[ -r $INFRA_ETC_DIR/repo.env ]]; then awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$INFRA_ETC_DIR/repo.env"; else printf '%s\n' "$fallback"; fi; }
update_installed_commit() { update_repo_value COMMIT ''; }
update_current_commit() { if [[ -d $INFRA_ROOT/.git ]]; then git -C "$INFRA_ROOT" rev-parse HEAD 2>/dev/null || true; else update_installed_commit; fi; }

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
  local requested_ref="${1:-}" expected="${2:-}" url ref parent stamp new
  core_require_root || return; core_acquire_lock || return; platform_detect_all || return; platform_require_free_space 220 || return; update_assert_install_target_safe || return
  url="$(update_repo_value URL "$INFRA_REPO_URL")"; ref="${requested_ref:-$(update_repo_value REF "$INFRA_REPO_REF")}"
  if ! core_safe_ref "$ref"; then core_die 'ref 无效'; return 1; fi
  if [[ -n $expected && ! $expected =~ ^[0-9a-fA-F]{40}$ ]]; then core_die '期望提交必须为 40 位 SHA'; return 1; fi
  parent="$(dirname "$INFRA_INSTALL_DIR")"; stamp="$(core_unique_stamp)"; UPDATE_STAGING_DIR="${INFRA_INSTALL_DIR}.staging.$stamp"; UPDATE_PREVIOUS_DIR="${INFRA_INSTALL_DIR}.backup.$stamp"
  core_register_failure_hook update_failure_restore
  core_run_step '拉取 Git 仓库' update_stage_source "$url" "$ref" "$UPDATE_STAGING_DIR"
  new="$UPDATE_STAGED_COMMIT"
  if [[ -n $expected && ${new,,} != ${expected,,} ]]; then core_die '提交校验失败'; return 1; fi
  core_run_step '执行结构、语法、链接和 Smoke 检查' update_preflight_tree "$UPDATE_STAGING_DIR"
  update_prepare_command_links
  [[ -e $INFRA_INSTALL_DIR ]] && { mv -T -- "$INFRA_INSTALL_DIR" "$UPDATE_PREVIOUS_DIR"; UPDATE_SWAP_COMPLETE=1; }
  mv -T -- "$UPDATE_STAGING_DIR" "$INFRA_INSTALL_DIR"; UPDATE_STAGING_DIR=''; UPDATE_SWAP_COMPLETE=1
  update_apply_command_links; update_write_repo_metadata "$url" "$ref" "$new"; "$INFRA_INSTALL_DIR/bin/infra-node" version >/dev/null
  UPDATE_FINALIZING=1; txn_commit; UPDATE_SWAP_COMPLETE=0; core_unregister_failure_hook update_failure_restore; UPDATE_FINALIZING=0
  update_prune_backups "$parent" "$(basename "$INFRA_INSTALL_DIR")"; ui_ok "已更新到 ${new:0:12}。"
}

update_copy_local_tree() {
  local source="$1" destination="$2"
  if [[ ! -d $source || -L $source ]]; then core_die '本地源码目录无效。'; return 1; fi
  update_tree_has_only_regular_entries "$source" || return
  update_validate_symlinks "$source" || return
  rm -rf -- "$destination"; install -d -m 0755 "$destination"
  tar -C "$source" --exclude='./.git' --exclude='./dist' --exclude='./.DS_Store' --no-xattrs --no-acls --no-selinux -cf - .     | tar -C "$destination" --no-same-owner --no-xattrs --no-acls --no-selinux -xf -
  UPDATE_STAGED_COMMIT="$(git -C "$source" rev-parse HEAD 2>/dev/null || true)"
  UPDATE_STAGED_FROM_LOCAL=1
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
