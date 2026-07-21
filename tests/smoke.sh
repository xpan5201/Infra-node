#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/infra-node-smoke.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
export INFRA_TEST_MODE=1 TMPDIR="$TMP/tmp"
mkdir -p "$TMPDIR"

# shellcheck disable=SC1091
source "$ROOT/config/defaults.env"
INFRA_ROOT="$ROOT"
INFRA_VERSION="$(cat "$ROOT/VERSION")"
INFRA_INSTALL_DIR="$TMP/install"
INFRA_COMMAND_DIR="$TMP/bin"
INFRA_ETC_DIR="$TMP/etc"
INFRA_STATE_DIR="$TMP/state"
INFRA_LOG_DIR="$TMP/log"
INFRA_BACKUP_DIR="$TMP/backup"
for lib in ui core platform packages transaction updater; do source "$ROOT/lib/$lib.sh"; done
for module in assessment base network proxy firewall audit experience deploy; do source "$ROOT/lib/modules/$module.sh"; done
source "$ROOT/lib/tui.sh"
ui_detect
core_init smoke

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" <<<"$1" || fail "$3"; }
assert_not_contains() { ! grep -Eqi -- "$2" <<<"$1" || fail "$3"; }

[[ $INFRA_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail 'VERSION format'
pass 'VERSION format'

"$ROOT/bin/infra-node" version | grep -Fq "$INFRA_VERSION" || fail 'version command'
"$ROOT/bin/infra-node" help | grep -Fq '不部署代理服务' || fail 'help boundary'
pass 'CLI version and help'

update_tree_has_only_regular_entries "$ROOT"
update_validate_symlinks "$ROOT"
update_validate_checksum_manifest "$ROOT"
pass 'checksum and tree validation'

mkdir -p "$TMP/modes/bin" "$TMP/modes/tests"
for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do
  mkdir -p "$TMP/modes/$(dirname "$path")"
  cp "$ROOT/$path" "$TMP/modes/$path"
  chmod 0644 "$TMP/modes/$path"
done
update_normalize_entrypoint_modes "$TMP/modes"
for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do [[ -x $TMP/modes/$path ]] || fail "mode normalization $path"; done
pass '0644 entrypoint normalization regression'

sysctl_text="$(network_build_sysctl balanced)"
assert_contains "$sysctl_text" 'tcp_mtu_probing = 1' 'conservative sysctl missing'
assert_not_contains "$sysctl_text" 'swappiness|tcp_keepalive|ip_local_port_range|tcp_fastopen|rmem_max|wmem_max' 'intrusive sysctl found'
pass 'conservative network policy'

ASSESS_PROFILE=balanced
limits="$(proxy_limits_for_profile balanced)"
assert_contains "$limits" '262144' 'proxy limits profile'
! grep -RqsE 'ExecStart=.*(xray|sing-box|hysteria)|curl.+(xray|sing-box|hysteria)|wget.+(xray|sing-box|hysteria)' "$ROOT/lib" "$ROOT/bin" || fail 'proxy deployment boundary'
pass 'proxy deployment boundary'

FIREWALL_TCP_PORTS=(22 443); FIREWALL_UDP_PORTS=(443)
rules="$(firewall_render_rules)"
assert_contains "$rules" 'table inet infra_node_filter' 'owned firewall table'
assert_contains "$rules" 'tcp dport { 22, 443 } accept' 'firewall tcp ports'
assert_contains "$rules" 'ct state established,related accept' 'firewall established state'
pass 'firewall rendering'

sample="$TMP/sample.conf"; printf 'before\n' >"$sample"
txn_begin smoke-rollback; txn_write_file "$sample" 0600 <<<'after'; txn_rollback
grep -Fxq before "$sample" || fail 'transaction rollback'
TXN_OUTCOME=none; TXN_PATHS=(); txn_begin smoke-commit; txn_write_file "$sample" 0600 <<<'committed'; txn_commit; txn_rollback
grep -Fxq committed "$sample" || fail 'committed transaction must not rollback'
pass 'transaction rollback and commit boundary'

marker="$TMP/should-not-exist"
if MARKER="$marker" ROOT="$ROOT" TESTBASE="$TMP/run-step" bash -c '
  set -Eeuo pipefail
  source "$ROOT/lib/ui.sh"
  source "$ROOT/lib/core.sh"
  INFRA_LOG_DIR="$TESTBASE/log"; INFRA_STATE_DIR="$TESTBASE/state"; INFRA_BACKUP_DIR="$TESTBASE/backup"
  ui_detect; core_init
  failing_step() { false; touch "$MARKER"; }
  core_run_step failure-propagation failing_step
' >/dev/null 2>&1; then
  fail 'core_run_step masked a command failure'
fi
[[ ! -e $marker ]] || fail 'core_run_step continued after failure'
pass 'step failure propagation'

redacted="$(core_redact 'curl https://example.test/path?token=abc password=hunter2')"
assert_not_contains "$redacted" 'abc|hunter2' 'log redaction leaked a secret'
assert_contains "$redacted" '[REDACTED]' 'log redaction marker missing'
pass 'log redaction'

NETWORK_SYSCTL_PATH="$TMP/sysctl.conf"
ASSESS_PROFILE=balanced
network_apply_sysctl
printf '%s\n' "${CORE_FAILURE_HOOKS[@]}" | grep -Fxq network_restore_runtime || fail 'network runtime hook removed before commit'
network_commit_runtime
! printf '%s\n' "${CORE_FAILURE_HOOKS[@]}" | grep -Fxq network_restore_runtime || fail 'network runtime hook remained after commit'
pass 'network runtime rollback lifetime'

# A late signal/error after the persistent transaction is committed must not
# revert live sysctls, remove committed Swap, or restore an old firewall.
TXN_OUTCOME=committed
NETWORK_SWAP_CREATED=1
swapoff() { touch "$TMP/swapoff-called"; }
network_rollback_swap
[[ ! -e $TMP/swapoff-called ]] || fail 'committed swap was rolled back'
unset -f swapoff
network_restore_runtime
firewall_runtime_rollback
TXN_OUTCOME=none
NETWORK_SWAP_CREATED=0
pass 'runtime hooks honor committed boundary'

# Regression: bootstrap must release the installer lock before exec'ing deploy.
grep -A8 -F "if ui_confirm '立即部署节点基础设施？' yes; then" "$ROOT/bootstrap.sh"   | grep -Fq 'core_release_lock' || fail 'bootstrap handoff does not release lock'
LOCK_TEST_STATE="$TMP/lock-state"
INFRA_STATE_DIR="$LOCK_TEST_STATE"
core_acquire_lock
core_release_lock
(
  CORE_LOCK_FD=''
  core_acquire_lock
  core_release_lock
) || fail 'lock cannot be reacquired after handoff release'
pass 'bootstrap lock handoff regression'

# Regression: an absent proxy unit is an expected predicate miss, not an ERR trap.
mkdir -p "$TMP/fake-bin" "$TMP/proxy-probe"
cat >"$TMP/fake-bin/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
case "${1:-}" in
  list-unit-files) exit 0 ;;
  *) exit 0 ;;
esac
EOF_SYSTEMCTL
chmod 0755 "$TMP/fake-bin/systemctl"
proxy_probe_output="$(PATH="$TMP/fake-bin:$PATH" ROOT="$ROOT" TESTBASE="$TMP/proxy-probe" bash -c '
  set -Eeuo pipefail
  source "$ROOT/config/defaults.env"
  INFRA_LOG_DIR="$TESTBASE/log"
  INFRA_STATE_DIR="$TESTBASE/state"
  INFRA_BACKUP_DIR="$TESTBASE/backup"
  source "$ROOT/lib/ui.sh"
  source "$ROOT/lib/core.sh"
  source "$ROOT/lib/platform.sh"
  source "$ROOT/lib/transaction.sh"
  source "$ROOT/lib/modules/proxy.sh"
  platform_has_systemd() { return 0; }
  ui_detect
  core_init proxy-probe
  proxy_apply auto no
' 2>&1)" || fail 'proxy absent-unit probe returned failure'
assert_contains "$proxy_probe_output" '未发现已安装的受支持代理服务' 'proxy absent-unit message missing'
assert_not_contains "$proxy_probe_output" '操作失败|执行命令|grep -q' 'proxy absent unit triggered ERR trap'
pass 'proxy absent-unit ERR-trap regression'

# First install uses a non-existent target path; free-space preflight must probe
# the nearest existing parent instead of silently skipping df.
DF_PROBE_FILE="$TMP/df-probe"
df() {
  printf '%s\n' "${3:-}" >"$DF_PROBE_FILE"
  printf '%s\n' 'Filesystem 1048576-blocks Used Available Capacity Mounted on' 'testfs 1000 1 999 1% /'
}
INFRA_INSTALL_DIR="$TMP/not-yet-created/deeper/infra-node"
platform_require_free_space 1
[[ $(cat "$DF_PROBE_FILE") == "$TMP" ]] || fail 'free-space preflight did not use existing parent'
unset -f df
pass 'first-install free-space preflight'

# Permission auditing must compare permission bits, not decimal mode values.
mode_file="$TMP/mode-test"
printf 'x\n' >"$mode_file"
chmod 0444 "$mode_file"
AUDIT_WARNINGS=0
audit_file_mode "$mode_file" 600 >/dev/null
((AUDIT_WARNINGS == 1)) || fail 'audit accepted group/other-readable mode 0444 under max 0600'
pass 'permission-bit audit'

for file in "$ROOT"/bootstrap.sh "$ROOT"/proxy-vps-foundation.sh "$ROOT"/bin/infra-node "$ROOT"/lib/*.sh "$ROOT"/lib/modules/*.sh "$ROOT"/tests/smoke.sh; do bash -n "$file" || fail "bash syntax ${file#$ROOT/}"; done
pass 'Bash syntax'

printf 'Smoke tests passed.\n'
