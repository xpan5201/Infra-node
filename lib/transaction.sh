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

txn_restore_entry() {
  local source="$1" key="$2" path type mode target=''
  [[ -r $source/files/$key.meta && -r $source/files/$key.path.b64 ]] || return 1
  path="$(_txn_b64_read "$source/files/$key.path.b64")"
  type="$(_txn_meta_value "$source/files/$key.meta" TYPE)"
  mode="$(_txn_meta_value "$source/files/$key.meta" MODE)"
  [[ -n $path && $path == /* ]] || return 1
  rm -rf -- "$path"
  case "$type" in
    file|directory)
      [[ -e $source/files/$key.data ]] || return 1
      mkdir -p -- "$(dirname "$path")"
      cp -a -- "$source/files/$key.data" "$path"
      [[ -n $mode ]] && chmod "$mode" "$path"
      ;;
    symlink)
      [[ -r $source/files/$key.target.b64 ]] || return 1
      target="$(_txn_b64_read "$source/files/$key.target.b64")"
      mkdir -p -- "$(dirname "$path")"
      ln -s -- "$target" "$path"
      ;;
    missing) : ;;
    *) return 1 ;;
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
  local id="$1" source="$INFRA_BACKUP_DIR/transactions/$id" path_file key
  [[ $id =~ ^[A-Za-z0-9._-]+$ ]] || core_die '事务 ID 无效。'
  [[ -d $source/files ]] || core_die "事务不存在：$id"
  core_require_root
  while IFS= read -r -d '' path_file; do
    key="$(basename "$path_file" .path.b64)"
    txn_restore_entry "$source" "$key" || core_die "事务条目恢复失败：$key"
  done < <(find "$source/files" -maxdepth 1 -type f -name '*.path.b64' -print0 | sort -z)
}
