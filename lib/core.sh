#!/usr/bin/env bash

CORE_LOG_FILE=''
CORE_LOCK_FD=''
CORE_STAGE='startup'
CORE_FAILURE_HOOKS=()
CORE_TMP_PATHS=()
CORE_ORIGINAL_ARGS=()
CORE_TRAP_ACTIVE=0

core_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
core_redact() {
  sed -E 's#(https://[^[:space:]?]+)\?[^[:space:]]+#\1?[REDACTED]#g; s#((token|secret|password|passwd|key)=)[^[:space:]&]+#\1[REDACTED]#Ig' <<<"$*"
}
core_unique_stamp() { printf '%s-%s-%05d\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$((RANDOM % 100000))"; }

core_log() {
  local level="$1"; shift
  [[ -n ${CORE_LOG_FILE:-} ]] || return 0
  printf '%s level=%s stage=%q message=%q\n' "$(core_now)" "$level" "$CORE_STAGE" "$*" >>"$CORE_LOG_FILE" 2>/dev/null || true
}

core_rotate_logs() {
  local i keep="${INFRA_LOG_KEEP:-5}"
  [[ $keep =~ ^[0-9]+$ && $keep -ge 1 ]] || keep=5
  rm -f -- "${CORE_LOG_FILE}.${keep}"
  for ((i=keep-1; i>=1; i--)); do
    [[ -e ${CORE_LOG_FILE}.${i} ]] && mv -f -- "${CORE_LOG_FILE}.${i}" "${CORE_LOG_FILE}.$((i+1))"
  done
  [[ -s $CORE_LOG_FILE ]] && mv -f -- "$CORE_LOG_FILE" "${CORE_LOG_FILE}.1"
}

core_init() {
  CORE_ORIGINAL_ARGS=("$@")
  umask 077
  if [[ ${INFRA_TEST_MODE:-0} -eq 1 ]]; then
    : "${INFRA_LOG_DIR:=${TMPDIR:-/tmp}/infra-node-test-log}"
    : "${INFRA_STATE_DIR:=${TMPDIR:-/tmp}/infra-node-test-state}"
    : "${INFRA_BACKUP_DIR:=${TMPDIR:-/tmp}/infra-node-test-backup}"
  fi
  mkdir -p -- "$INFRA_LOG_DIR" "$INFRA_STATE_DIR" "$INFRA_BACKUP_DIR" 2>/dev/null || true
  CORE_LOG_FILE="$INFRA_LOG_DIR/infra-node.log"
  touch "$CORE_LOG_FILE" 2>/dev/null || CORE_LOG_FILE=/dev/null
  chmod 0600 "$CORE_LOG_FILE" 2>/dev/null || true
  trap 'core_on_error $? $LINENO "$BASH_COMMAND"' ERR
  trap 'core_on_signal INT' INT
  trap 'core_on_signal TERM' TERM
  trap 'core_on_exit $?' EXIT
}

core_stage() { CORE_STAGE="$*"; core_log INFO "stage entered"; }
core_require_root() { [[ ${INFRA_TEST_MODE:-0} -eq 1 || $(id -u) -eq 0 ]] || core_die '此操作需要 root 权限。'; }
core_register_tmp() { CORE_TMP_PATHS+=("$1"); }
core_unregister_tmp() { local p="$1" out=() x; for x in "${CORE_TMP_PATHS[@]}"; do [[ $x == "$p" ]] || out+=("$x"); done; CORE_TMP_PATHS=("${out[@]}"); }
core_register_failure_hook() { CORE_FAILURE_HOOKS+=("$1"); }
core_unregister_failure_hook() { local f="$1" out=() x; for x in "${CORE_FAILURE_HOOKS[@]}"; do [[ $x == "$f" ]] || out+=("$x"); done; CORE_FAILURE_HOOKS=("${out[@]}"); }

core_run_failure_hooks() {
  local i
  for ((i=${#CORE_FAILURE_HOOKS[@]}-1; i>=0; i--)); do "${CORE_FAILURE_HOOKS[$i]}" || core_log ERROR "failure hook failed: ${CORE_FAILURE_HOOKS[$i]}"; done
}

core_cleanup_tmp() { local p; for p in "${CORE_TMP_PATHS[@]}"; do [[ -n $p ]] && rm -rf -- "$p" 2>/dev/null || true; done; CORE_TMP_PATHS=(); }

core_on_error() {
  local rc="$1" line="$2" command="$3"
  (( CORE_TRAP_ACTIVE == 0 )) || return "$rc"
  CORE_TRAP_ACTIVE=1
  trap - ERR
  command="$(core_redact "$command")"
  core_log ERROR "rc=$rc line=$line command=$command"
  ui_error "操作失败：阶段=${CORE_STAGE}，退出码=${rc}，行=${line}。"
  ui_error "执行命令：${command}"
  [[ $CORE_LOG_FILE != /dev/null ]] && ui_warn "详细日志：${CORE_LOG_FILE}"
  core_run_failure_hooks
  CORE_TRAP_ACTIVE=0
  return "$rc"
}

core_on_signal() {
  local sig="$1"
  trap - ERR INT TERM
  core_log ERROR "signal=$sig"
  ui_error "收到信号 ${sig}，正在恢复未提交更改。"
  core_run_failure_hooks
  [[ $sig == INT ]] && exit 130
  exit 143
}

core_on_exit() {
  local rc="$1"
  core_cleanup_tmp
  core_release_lock
  return "$rc"
}

core_die() { core_log ERROR "$*"; ui_error "$*"; return 1; }

core_acquire_lock() {
  local lock="$INFRA_STATE_DIR/infra-node.lock"
  mkdir -p -- "$INFRA_STATE_DIR"
  exec {CORE_LOCK_FD}>"$lock"
  flock -n "$CORE_LOCK_FD" || core_die '已有另一个 Infra-node 操作正在运行。'
}
core_release_lock() { if [[ -n ${CORE_LOCK_FD:-} ]]; then flock -u "$CORE_LOCK_FD" 2>/dev/null || true; eval "exec ${CORE_LOCK_FD}>&-" 2>/dev/null || true; CORE_LOCK_FD=''; fi; }

core_safe_ref() { [[ $1 =~ ^[A-Za-z0-9._/@+-]{1,200}$ && $1 != -* && $1 != *'..'* && $1 != *'@{'* ]]; }
core_safe_repo_url() {
  local url="$1"
  [[ $url =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+(\.git)?$ || $url =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+(\.git)?$ ]]
}
core_safe_unit() { [[ $1 =~ ^[A-Za-z0-9_.@-]+\.service$ ]]; }
core_valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

core_atomic_write() {
  local path="$1" mode="$2" dir tmp
  dir="$(dirname "$path")"; mkdir -p -- "$dir"
  tmp="$(mktemp "${dir}/.infra-node.XXXXXX")"; core_register_tmp "$tmp"
  cat >"$tmp"; chmod "$mode" "$tmp"; mv -fT -- "$tmp" "$path"; core_unregister_tmp "$tmp"
}

core_run_step() {
  local label="$1"; shift
  core_stage "$label"
  ui_info "$label..."
  # Do not call the step from an `if` condition: Bash suppresses errexit for the
  # complete function body in that context and can hide an early failure.
  "$@"
  ui_ok "$label"
}

core_dry_run_cmd() {
  if [[ ${INFRA_DRY_RUN:-0} -eq 1 ]]; then printf '[dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
