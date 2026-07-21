#!/usr/bin/env bash

TXN_ID=''
TXN_DIR=''
TXN_OUTCOME=none
TXN_PATHS=()

_txn_key() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
_txn_b64_write() { printf '%s' "$1" | base64 -w0 >"$2"; }
_txn_b64_read() { base64 -d <"$1"; }
_txn_meta_value() { awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/,""); print; exit}' "$1"; }

txn_begin() {
  local label="${1:-transaction}"
  [[ $TXN_OUTCOME == active ]] && return 0
  TXN_ID="$(core_unique_stamp)"
  TXN_DIR="$INFRA_BACKUP_DIR/transactions/$TXN_ID"
  TXN_OUTCOME=active
  TXN_PATHS=()
  mkdir -p -- "$TXN_DIR/files"
  printf 'LABEL_B64=' >"$TXN_DIR/meta.env"; printf '%s' "$label" | base64 -w0 >>"$TXN_DIR/meta.env"
  printf '\nSTARTED_AT=%s\n' "$(core_now)" >>"$TXN_DIR/meta.env"
  chmod 0600 "$TXN_DIR/meta.env"
  core_register_failure_hook txn_rollback
}

txn_snapshot() {
  local path="$1" key meta existing type mode=''
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
  local -a keys=()
  source="$INFRA_BACKUP_DIR/transactions/$id"
  if [[ ! $id =~ ^[A-Za-z0-9._-]+$ ]]; then core_die '事务 ID 无效。'; return 1; fi
  if [[ ! -d $source/files ]]; then core_die "事务不存在：$id"; return 1; fi
  core_require_root || return
  while IFS= read -r -d '' path_file; do
    key="$(basename "$path_file" .path.b64)"
    if ! txn_validate_entry "$source" "$key"; then core_die "事务条目损坏：$key"; return 1; fi
    keys+=("$key")
  done < <(find "$source/files" -maxdepth 1 -type f -name '*.path.b64' -print0 | sort -z)
  ((${#keys[@]} > 0)) || { ui_warn '事务中没有可恢复的文件。'; return 0; }

  # Snapshot the current state first, so a restore that fails midway can itself
  # be rolled back by the normal transaction failure hook.
  txn_begin "restore transaction $id"
  for key in "${keys[@]}"; do
    path="$(_txn_b64_read "$source/files/$key.path.b64")"
    txn_snapshot "$path"
  done
  for key in "${keys[@]}"; do
    if ! txn_restore_entry "$source" "$key"; then core_die "事务条目恢复失败：$key"; return 1; fi
  done
  txn_commit
  ui_ok "事务 $id 已恢复；恢复前状态已保存为新事务。"
}
