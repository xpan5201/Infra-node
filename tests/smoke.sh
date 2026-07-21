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

for file in "$ROOT"/bootstrap.sh "$ROOT"/proxy-vps-foundation.sh "$ROOT"/bin/infra-node "$ROOT"/lib/*.sh "$ROOT"/lib/modules/*.sh "$ROOT"/tests/smoke.sh; do bash -n "$file" || fail "bash syntax ${file#$ROOT/}"; done
pass 'Bash syntax'

printf 'Smoke tests passed.\n'
