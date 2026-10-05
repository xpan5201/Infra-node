#!/usr/bin/env bash

TXN_ID=''
TXN_DIR=''
TXN_OUTCOME=none
TXN_PATHS=()

_txn_key() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
_txn_b64_write() { printf '%s' "$1" | base64 -w0 >"$2"; }
_txn_b64_read() { base64 -d <"$1"; }
_txn_meta_value() { awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/,""); print; exit}' "$1"; }

# Fixed-path contract, derived live so the test suite can relocate INFRA_* and the
# module-level path variables without weakening the boundary.
# Entries ending in `/` are directory prefixes; everything else must match exactly.
TXN_ALLOWED_PATHS=()
txn_allowed_paths() {
  if ((${#TXN_ALLOWED_PATHS[@]})); then printf '%s\n' "${TXN_ALLOWED_PATHS[@]}"; return 0; fi
  # Directory contracts: everything below them is allowed.
  printf '%s\n' \
    "${INFRA_INSTALL_DIR:-/opt/infra-node}/" \
    "${INFRA_COMMAND_DIR:-/usr/local/bin}/" \
    "${INFRA_ETC_DIR:-/etc/infra-node}/" \
    "${INFRA_STATE_DIR:-/var/lib/infra-node}/" \
    "${INFRA_LOG_DIR:-/var/log/infra-node}/" \
    "${INFRA_BACKUP_DIR:-/var/backups/infra-node}/" \
    "${NETWORK_MODULES_LOAD_DIR:-/etc/modules-load.d}/" \
    '/etc/sysctl.d/' \
    '/etc/systemd/' \
    '/etc/apt/' \
    '/usr/local/libexec/' \
    '/run/infra-node/'
  # Exact single files.
  printf '%s\n' \
    "${NETWORK_SYSCTL_PATH:-/etc/sysctl.d/99-infra-node.conf}" \
    "${NETWORK_SWAP_PATH:-/swapfile.infra-node}" \
    "${NETWORK_FSTAB_PATH:-/etc/fstab}"
}

txn_path_allowed() {
  local candidate normalized prefix
  candidate="${1:-}"
  [[ -n $candidate && $candidate == /* ]] || return 1
  normalized="$(readlink -m -- "$candidate" 2>/dev/null || true)"
  [[ -n $normalized ]] || return 1
  while IFS= read -r prefix; do
    [[ -n $prefix ]] || continue
    # Directory prefix: compare at a path-component boundary so /etc/apt-evil
    # does not match the /etc/apt/ contract.
    [[ $prefix == */ && $normalized == "$prefix"* ]] && return 0
    [[ $normalized == "$prefix" ]] && return 0
  done < <(txn_allowed_paths)
  return 1
}

txn_require_path_allowed() {
  local path="$1" origin="${2:-transaction}"
  txn_path_allowed "$path" && return 0
  core_log ERROR "transaction path outside contract: $path"
  core_die "事务目标越界，拒绝操作：${path}（来源：${origin}）"
  return 1
}

txn_begin() {
  local label="${1:-transaction}"
  [[ $TXN_OUTCOME == active ]] && return 0
  TXN_ID="$(core_unique_stamp)"
  TXN_DIR="$INFRA_BACKUP_DIR/transactions/$TXN_ID"
  TXN_OUTCOME=active
  TXN_PATHS=()
  if ! mkdir -p -- "$TXN_DIR/files" 2>/dev/null; then
    TXN_OUTCOME=none
    core_die "无法创建事务目录：$TXN_DIR（请以 root 运行写入类命令）"
    return 1
  fi
  printf 'LABEL_B64=' >"$TXN_DIR/meta.env"; printf '%s' "$label" | base64 -w0 >>"$TXN_DIR/meta.env"
  printf '\nSTARTED_AT=%s\n' "$(core_now)" >>"$TXN_DIR/meta.env"
  chmod 0600 "$TXN_DIR/meta.env"
  core_register_failure_hook txn_rollback
}

txn_snapshot() {
  local path="$1" key meta existing type mode=''
  txn_require_path_allowed "$path" snapshot || return 1
  [[ $TXN_OUTCOME == active ]] || txn_begin automatic
  for existing in "${TXN_PATHS[@]}"; do [[ $existing == "$path" ]] && return 0; done
  TXN_PATHS+=("$path")
  key="$(_txn_key "$path")"
  meta="$TXN_DIR/files/$key.meta"
  _txn_b64_write "$path" "$TXN_DIR/files/$key.path.b64"
  if [[ -L $path ]]; then
    type=symlink
    _txn_b64_write "$(readlink "$path")" "$TXN_DIR/files/$key.target.b64"
  elif [[ -f $path ]]; then
    # shellcheck disable=SC2209  # `type=file` is a literal string, not a command.
    type=file; mode="$(stat -c %a "$path")"; cp -a -- "$path" "$TXN_DIR/files/$key.data"
  elif [[ -d $path ]]; then
    type=directory; mode="$(stat -c %a "$path")"; cp -a -- "$path" "$TXN_DIR/files/$key.data"
  else
    type=missing
  fi
  printf 'TYPE=%s\nMODE=%s\n' "$type" "$mode" >"$meta"
  chmod 0600 "$meta" "$TXN_DIR/files/$key.path.b64"
}

txn_write_file() {
  local path="$1" mode="$2"
  txn_snapshot "$path"
  core_atomic_write "$path" "$mode"
}

txn_remove() {
  local path="$1"
  txn_snapshot "$path"
  rm -rf -- "$path"
}

txn_validate_entry() {
  local source="$1" key="$2" path type
  [[ -r $source/files/$key.meta && -r $source/files/$key.path.b64 ]] || return 1
  path="$(_txn_b64_read "$source/files/$key.path.b64")"
  type="$(_txn_meta_value "$source/files/$key.meta" TYPE)"
  [[ -n $path && $path == /* ]] || return 1
  txn_path_allowed "$path" || return 1
  case "$type" in
    file) [[ -f $source/files/$key.data && ! -L $source/files/$key.data ]] ;;
    directory) [[ -d $source/files/$key.data && ! -L $source/files/$key.data ]] ;;
    symlink) [[ -r $source/files/$key.target.b64 ]] ;;
    missing) return 0 ;;
    *) return 1 ;;
  esac
}

txn_restore_entry() {
  local source="$1" key="$2" path type mode target=''
  txn_validate_entry "$source" "$key" || return 1
  path="$(_txn_b64_read "$source/files/$key.path.b64")"
  # Refuse to delete anything outside the fixed-path contract. This is the last
  # gate before `rm -rf`, so it must stay even when callers pre-validated.
  txn_path_allowed "$path" || { core_log ERROR "refusing out-of-contract restore: $path"; return 1; }
  type="$(_txn_meta_value "$source/files/$key.meta" TYPE)"
  mode="$(_txn_meta_value "$source/files/$key.meta" MODE)"
  case "$type" in
    symlink) target="$(_txn_b64_read "$source/files/$key.target.b64")" ;;
  esac
  rm -rf -- "$path"
  case "$type" in
    file|directory)
      mkdir -p -- "$(dirname "$path")"
      cp -a -- "$source/files/$key.data" "$path"
      [[ -n $mode ]] && chmod "$mode" "$path"
      ;;
    symlink)
      mkdir -p -- "$(dirname "$path")"
      ln -s -- "$target" "$path"
      ;;
    missing) : ;;
  esac
}

txn_commit() {
  [[ $TXN_OUTCOME == active ]] || return 0
  printf '%s\n' "$(core_now)" >"$TXN_DIR/committed-at"
  chmod 0600 "$TXN_DIR/committed-at"
  TXN_OUTCOME=committed
  core_unregister_failure_hook txn_rollback
}

txn_rollback() {
  local had_e=0 i path key
  [[ $- == *e* ]] && had_e=1
  set +e
  [[ $TXN_OUTCOME == active ]] || { ((had_e==0)) || set -e; return 0; }
  for ((i=${#TXN_PATHS[@]}-1; i>=0; i--)); do
    path="${TXN_PATHS[$i]}"
    key="$(_txn_key "$path")"
    txn_restore_entry "$TXN_DIR" "$key" || core_log ERROR "transaction restore failed: $path"
  done
  printf '%s\n' "$(core_now)" >"$TXN_DIR/rolled-back-at"
  chmod 0600 "$TXN_DIR/rolled-back-at" 2>/dev/null || true
  TXN_OUTCOME=rolled_back
  core_unregister_failure_hook txn_rollback
  ((had_e==0)) || set -e
  return 0
}

txn_list() {
  local d status
  [[ -d $INFRA_BACKUP_DIR/transactions ]] || { echo '暂无事务备份。'; return; }
  for d in "$INFRA_BACKUP_DIR"/transactions/*; do
    [[ -d $d ]] || continue
    status=incomplete
    [[ -f $d/committed-at ]] && status=committed
    [[ -f $d/rolled-back-at ]] && status=rolled-back
    printf '%s\t%s\n' "$(basename "$d")" "$status"
  done | sort -r
}

txn_restore_id() {
  local id="$1" source path_file key path
  local -a keys=() paths=()
  if [[ ! $id =~ ^[A-Za-z0-9._-]+$ ]]; then core_die '事务 ID 无效。'; return 1; fi
  source="$INFRA_BACKUP_DIR/transactions/$id"
  if [[ ! -d $source/files ]]; then core_die "事务不存在：$id"; return 1; fi
  core_require_root || return
  # Full pre-pass, then mutate. A single out-of-contract or corrupt entry must
  # abort the whole restore before anything is deleted.
  while IFS= read -r -d '' path_file; do
    key="$(basename "$path_file" .path.b64)"
    if ! txn_validate_entry "$source" "$key"; then core_die "事务条目损坏或越界：$key"; return 1; fi
    path="$(_txn_b64_read "$source/files/$key.path.b64")"
    txn_path_allowed "$path" || { core_die "事务目标越界，拒绝整批恢复：$path"; return 1; }
    keys+=("$key"); paths+=("$path")
  done < <(find "$source/files" -maxdepth 1 -type f -name '*.path.b64' -print0 | sort -z)
  ((${#keys[@]} > 0)) || { ui_warn '事务中没有可恢复的文件。'; return 0; }

  # Snapshot the current state first, so a restore that fails midway can itself
  # be rolled back by the normal transaction failure hook.
  txn_begin "restore transaction $id"
  for path in "${paths[@]}"; do
    if ! txn_snapshot "$path"; then core_die "无法快照当前状态：$path"; return 1; fi
  done
  for key in "${keys[@]}"; do
    if ! txn_restore_entry "$source" "$key"; then core_die "事务条目恢复失败：$key"; return 1; fi
  done
  txn_commit
  ui_ok "事务 $id 已恢复；恢复前状态已保存为新事务。"
}
