#!/usr/bin/env bash
# This harness deliberately sets module-level globals and stubs helpers that are
# only ever called from the sourced libraries, and it sources them through a
# computed path. Neither is followable by shellcheck, so both checks are off for
# the whole file rather than sprinkled over ~25 individual sites.
# shellcheck disable=SC2034,SC1090,SC1091,SC2329,SC2016
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

# The released version must be discoverable from the user-facing docs. v1.6.2 shipped
# two CHANGELOG entries under one unchanged VERSION, so users could not tell a hotfix
# build from the original — assert the docs actually mention the current version.
grep -Fq "## $INFRA_VERSION" "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md has no '## $INFRA_VERSION' section"
grep -Fq "v$INFRA_VERSION" "$ROOT/README.md" || fail "README.md does not mention v$INFRA_VERSION"
if grep -Fq "unzip Infra-node-v" "$ROOT/README.md"; then
  grep -Fq "unzip Infra-node-v$INFRA_VERSION.zip" "$ROOT/README.md" || fail "README.md ZIP example is not named for v$INFRA_VERSION"
fi
pass 'version is reflected in README and CHANGELOG'

"$ROOT/bin/infra-node" version | grep -Fq "$INFRA_VERSION" || fail 'version command'
help_text="$("$ROOT/bin/infra-node" help)"
grep -Fq '不部署代理服务' <<<"$help_text" || fail 'help boundary'
grep -Fq 'firewall configure' <<<"$help_text" || fail 'firewall configure missing from help'
grep -Fq 'firewall show' <<<"$help_text" || fail 'firewall show missing from help'
pass 'CLI version and help'

update_tree_has_only_regular_entries "$ROOT"
update_validate_symlinks "$ROOT"
[[ ! -e $ROOT/CHECKSUMS.sha256 ]] || fail 'legacy checksum manifest still present'
! grep -RqsE 'CHECKSUMS\.sha256|sha256sum --strict -c' "$ROOT/lib" "$ROOT/bin" "$ROOT/bootstrap.sh" || fail 'runtime checksum gate still referenced'
pass 'structure checks without checksum manifest'

mkdir -p "$TMP/bad-tree"
printf 'ok\n' >"$TMP/bad-tree/regular"
mkfifo "$TMP/bad-tree/unsupported"
if update_tree_has_only_regular_entries "$TMP/bad-tree" >/dev/null 2>&1; then fail 'unsupported file type was masked in conditional context'; fi
rm -f "$TMP/bad-tree/unsupported"
# Windows Git-Bash cannot create symlinks without elevation, so a local run sets
# INFRA_SMOKE_SKIP_SYMLINKS=1 to skip the symlink-semantics assertions rather than
# pass them against emulated regular files. CI never sets it.
if [[ ${INFRA_SMOKE_SKIP_SYMLINKS:-0} -eq 1 ]]; then
  printf 'SKIP escaping-symlink assertion (INFRA_SMOKE_SKIP_SYMLINKS=1)\n'
else
  ln -s /etc/passwd "$TMP/bad-tree/escape"
  if update_validate_symlinks "$TMP/bad-tree" >/dev/null 2>&1; then fail 'escaping symlink was masked in conditional context'; fi
fi
pass 'repository preflight failures propagate in conditional context'

mkdir -p "$TMP/modes/bin" "$TMP/modes/tests"
for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do
  mkdir -p "$TMP/modes/$(dirname "$path")"
  cp "$ROOT/$path" "$TMP/modes/$path"
  chmod 0644 "$TMP/modes/$path"
done
update_normalize_entrypoint_modes "$TMP/modes"
for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do [[ -x $TMP/modes/$path ]] || fail "mode normalization $path"; done
pass '0644 entrypoint normalization regression'

# The support filter reads /proc/sys, so point it at a synthetic kernel that
# exposes every knob this project writes. Keeps the policy assertion deterministic
# instead of depending on the host kernel (IPv6 is absent on some CI hosts).
fake_proc="$TMP/fake-proc-sys"
for knob in net/core/somaxconn net/core/netdev_max_backlog net/core/rmem_max net/core/wmem_max \
            net/core/rmem_default net/core/wmem_default \
            net/ipv4/tcp_max_syn_backlog net/ipv4/tcp_mtu_probing net/ipv4/tcp_syncookies \
            net/ipv4/tcp_slow_start_after_idle net/ipv4/tcp_notsent_lowat \
            net/ipv4/tcp_rmem net/ipv4/tcp_wmem net/ipv4/tcp_fastopen \
            net/ipv4/udp_rmem_min net/ipv4/udp_wmem_min \
            net/ipv4/conf/all/accept_redirects net/ipv4/conf/default/accept_redirects \
            net/ipv4/conf/all/send_redirects net/ipv4/conf/default/send_redirects \
            net/ipv4/conf/all/accept_source_route net/ipv4/conf/default/accept_source_route \
            net/ipv6/conf/all/accept_redirects net/ipv6/conf/default/accept_redirects; do
  mkdir -p "$fake_proc/$(dirname "$knob")"
  printf '0\n' >"$fake_proc/$knob"
done
NETWORK_PROC_SYS="$fake_proc"
network_bbr_available() { return 1; }
# Keep the port-range decision off the host kernel: pretend an already-wide range.
sysctl() { [[ ${2:-} == net.ipv4.ip_local_port_range ]] && { printf '32768\t60999\n'; return 0; }; return 0; }
sysctl_text="$(network_build_sysctl balanced)"
assert_contains "$sysctl_text" 'tcp_mtu_probing = 1' 'sysctl missing mtu probing'
assert_contains "$sysctl_text" 'net.ipv6.conf.all.accept_redirects = 0' 'supported ipv6 knob was filtered out'
# Security posture must stay: no swappiness, no keepalive rewrite, no route weakening.
assert_not_contains "$sysctl_text" 'swappiness|tcp_keepalive|accept_source_route = 1|accept_redirects = 1' 'security-weakening sysctl found'
assert_not_contains "$sysctl_text" '^fs.file-max' 'fs.file-max is already the kernel ceiling; writing it is noise'
pass 'network security posture unchanged'

# Intentional proxy-performance tuning must actually be present (A tier).
assert_contains "$sysctl_text" 'net.ipv4.tcp_max_syn_backlog = 4096' 'syn backlog not raised alongside somaxconn'
assert_contains "$sysctl_text" 'net.ipv4.tcp_slow_start_after_idle = 0' 'slow start after idle not disabled'
assert_contains "$sysctl_text" 'net.ipv4.tcp_notsent_lowat = 131072' 'notsent_lowat not lowered'
assert_contains "$sysctl_text" 'net.ipv4.tcp_fastopen = 3' 'tcp_fastopen not enabled'
assert_contains "$sysctl_text" 'net.core.rmem_max = ' 'rmem_max ceiling missing'
assert_contains "$sysctl_text" 'net.core.wmem_max = ' 'wmem_max ceiling missing'
# UDP matters for QUIC / Hysteria / TUIC.
assert_contains "$sysctl_text" 'net.core.rmem_default = ' 'UDP receive default not raised'
assert_contains "$sysctl_text" 'net.core.wmem_default = ' 'UDP send default not raised'
assert_not_contains "$sysctl_text" 'ip_local_port_range' 'already-wide port range must not be rewritten'
pass 'proxy performance tuning present'

# Buffer ceilings scale with installed RAM so a small VPS is not over-committed.
mem_backup="$(platform_mem_mb)"
platform_mem_mb() { printf '512\n'; }
  [[ $(network_buffer_max_bytes) == '4194304' ]] || fail 'small-memory buffer ceiling wrong'
platform_mem_mb() { printf '2048\n'; }
  [[ $(network_buffer_max_bytes) == '8388608' ]] || fail 'mid-memory buffer ceiling wrong'
platform_mem_mb() { printf '8192\n'; }
  [[ $(network_buffer_max_bytes) == '16777216' ]] || fail 'large-memory buffer ceiling wrong'
platform_mem_mb() { printf '%s\n' "$mem_backup"; }
pass 'buffer ceiling scales with memory'

# A narrow ephemeral range must be widened; a wide one must be left alone.
sysctl() { printf '44620\t48715\n'; }
ports="$(network_ports_config)" || fail 'narrow ephemeral range was not widened'
assert_contains "$ports" 'net.ipv4.ip_local_port_range = 10240 65535' 'port range widening wrong'
sysctl() { printf '32768\t60999\n'; }
network_ports_config && fail 'already-wide ephemeral range was rewritten'
unset -f sysctl
pass 'ephemeral port range widened only when narrow'

# Regression for the silent-BBR bug: a host where tcp_bbr exists as an unloaded
# module must trigger modprobe + persistence, not a silent cubic fallback.
bbr_dir="$TMP/bbr"
mkdir -p "$bbr_dir/modules-load.d" "$bbr_dir/proc/net/ipv4"
printf 'reno cubic\n' >"$bbr_dir/proc/net/ipv4/tcp_available_congestion_control"
NETWORK_MODULES_LOAD_DIR="$bbr_dir/modules-load.d"
# NETWORK_PROC_SYS is a plain variable, but network_bbr_available was stubbed out
# with a hardcoded /proc path above, so re-point it at the synthetic kernel too.
network_bbr_available() {
  [[ -r $NETWORK_PROC_SYS/net/ipv4/tcp_available_congestion_control ]] \
    && grep -qw bbr "$NETWORK_PROC_SYS/net/ipv4/tcp_available_congestion_control"
}
bbr_loaded="$TMP/bbr-loaded"
modinfo() { return 0; }                                   # module ships with the kernel
modprobe() { printf 'reno cubic bbr\n' >"$bbr_dir/proc/net/ipv4/tcp_available_congestion_control"; touch "$bbr_loaded"; }
NETWORK_PROC_SYS="$bbr_dir/proc"
network_bbr_available && fail 'bbr reported available before the module was loaded'
network_ensure_bbr_module || fail 'tcp_bbr module was not loaded although it is present'
[[ -e $bbr_loaded ]] || fail 'modprobe was never invoked'
network_bbr_available || fail 'bbr still unavailable after loading the module'
# With BBR now available, bbr + fq must appear in the generated config.
# Build the synthetic kernel's knob tree explicitly; the support filter drops any
# key whose /proc/sys counterpart is absent, so a missing knob would look like a
# code failure.
for knob in net/core/somaxconn net/core/netdev_max_backlog net/core/rmem_max net/core/wmem_max \
            net/core/rmem_default net/core/wmem_default \
            net/ipv4/tcp_max_syn_backlog net/ipv4/tcp_mtu_probing net/ipv4/tcp_syncookies \
            net/ipv4/tcp_slow_start_after_idle net/ipv4/tcp_notsent_lowat \
            net/ipv4/tcp_rmem net/ipv4/tcp_wmem net/ipv4/tcp_fastopen \
            net/ipv4/tcp_congestion_control \
            net/ipv4/udp_rmem_min net/ipv4/udp_wmem_min; do
  mkdir -p "$bbr_dir/proc/$(dirname "$knob")"; printf '0\n' >"$bbr_dir/proc/$knob"
done
mkdir -p "$bbr_dir/proc/net/core"; printf '0\n' >"$bbr_dir/proc/net/core/default_qdisc"
bbr_text="$(network_build_sysctl balanced)"
assert_contains "$bbr_text" 'net.ipv4.tcp_congestion_control = bbr' 'bbr not written although available'
assert_contains "$bbr_text" 'net.core.default_qdisc = fq' 'fq not written alongside bbr'
bbr_state="$(network_report_bbr_state 2>&1)"
assert_contains "$bbr_state" 'BBR 可用' 'missing positive BBR report'
# Persisting the module is what keeps BBR alive across a reboot.
#
# This must run inside an ACTIVE transaction, exactly as network_apply_sysctl()
# does it: the persistence helper opens its own transaction, but a nested
# txn_begin() is a no-op, so outside a transaction the write would skip
# txn_write_file's path-contract gate and hide a real failure. That gate once
# rejected /etc/modules-load.d/ because the whitelist forgot it.
INFRA_TEST_MODE=0
TXN_OUTCOME=none; TXN_PATHS=()
txn_begin 'bbr persistence probe'
network_write_bbr_module_persistence || fail 'bbr module persistence was not written'
txn_commit
INFRA_TEST_MODE=1
TXN_OUTCOME=none; TXN_PATHS=()
bbr_conf="$NETWORK_MODULES_LOAD_DIR/50-infra-node-bbr.conf"
[[ -r $bbr_conf ]] || fail 'modules-load.d file missing'
grep -Fxq 'tcp_bbr' "$bbr_conf" || fail 'modules-load.d file does not request tcp_bbr'
# The path contract must follow NETWORK_MODULES_LOAD_DIR, so an overridden location
# is honoured. (That the *default* /etc/modules-load.d is also covered is asserted
# by docs/_local/check.sh, which runs this file in a clean environment.)
txn_path_allowed "$NETWORK_MODULES_LOAD_DIR/50-infra-node-bbr.conf" \
  || fail 'modules-load.d is missing from the transaction path contract'
pass 'tcp_bbr module is loaded and persisted'

# And when the kernel genuinely has no BBR, say so instead of pretending.
modinfo() { return 1; }
printf 'reno cubic\n' >"$bbr_dir/proc/net/ipv4/tcp_available_congestion_control"
nosys="$(network_report_bbr_state 2>&1)"
assert_contains "$nosys" '未提供 BBR' 'missing explicit no-BBR report'
none_text="$(network_build_sysctl balanced)"
assert_not_contains "$none_text" 'tcp_congestion_control = bbr' 'bbr written although unsupported'
unset -f modinfo modprobe
NETWORK_PROC_SYS="$fake_proc"
network_bbr_available() { return 1; }
pass 'absent BBR is reported, never silently skipped'

# A host that booted with ipv6.disable=1 has no /proc/sys/net/ipv6. Those keys must
# be dropped with a report instead of failing the whole deployment (P1-7).
rm -rf "$fake_proc/net/ipv6"
ipv4_text="$(network_build_sysctl balanced)"
assert_contains "$ipv4_text" 'tcp_mtu_probing = 1' 'ipv4 knobs dropped along with ipv6'
assert_not_contains "$ipv4_text" 'net\.ipv6' 'unsupported ipv6 knobs were still emitted'
[[ $(network_skipped_keys) == *net.ipv6.conf.all.accept_redirects* ]] || fail 'skipped ipv6 keys were not recorded'
report="$(network_report_skipped_keys 2>&1)"
assert_contains "$report" '已跳过' 'skipped-key report missing'
# And the runtime applier must not turn a missing knob into a hard failure.
NETWORK_SYSCTL_PATH="$TMP/sysctl-ipv6less.conf"
printf 'net.core.somaxconn = 4096\nnet.ipv6.conf.all.accept_redirects = 0\n' >"$NETWORK_SYSCTL_PATH"
sysctl() { return 0; }
INFRA_TEST_MODE=0
network_apply_sysctl_runtime || fail 'missing ipv6 knob aborted sysctl application'
INFRA_TEST_MODE=1
unset -f sysctl
# Restore a kernel that has every knob, so later assertions stay deterministic.
NETWORK_PROC_SYS="$fake_proc"
mkdir -p "$fake_proc/net/ipv6/conf/all" "$fake_proc/net/ipv6/conf/default"
printf '0\n' >"$fake_proc/net/ipv6/conf/all/accept_redirects"
printf '0\n' >"$fake_proc/net/ipv6/conf/default/accept_redirects"
network_build_sysctl balanced >/dev/null
network_bbr_available() { [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; }
NETWORK_PROC_SYS=/proc/sys
pass 'kernel-unsupported sysctl keys are skipped with a report'

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
FIREWALL_TCP_PORTS=(); FIREWALL_UDP_PORTS=()
firewall_parse_ports tcp '443,10000-10100,443'
[[ ${FIREWALL_TCP_PORTS[*]} == '443 10000-10100' ]] || fail 'firewall range normalization or deduplication'
if firewall_parse_ports udp '65536' >/dev/null 2>&1; then fail 'invalid firewall port accepted'; fi
if firewall_parse_ports udp '999999999999999999999999' >/dev/null 2>&1; then fail 'oversized firewall port accepted'; fi
show_output="$(PATH=/nonexistent firewall_show 2>&1)" || fail 'firewall show should be non-fatal when nft is absent'
assert_contains "$show_output" '未启用' 'firewall show missing disabled message'
helper_text="$(firewall_render_helper /usr/sbin/nft)"
unit_text="$(firewall_render_unit)"
assert_contains "$helper_text" 'delete table inet infra_node_filter' 'firewall persistence helper does not replace only the owned table'
assert_contains "$helper_text" '"$NFT" -c -f' 'firewall persistence helper missing syntax preflight'
assert_contains "$unit_text" 'RemainAfterExit=yes' 'firewall persistence unit is not stateful'
assert_contains "$unit_text" 'ConditionPathExists=/etc/infra-node/firewall.nft' 'firewall persistence unit missing config guard'
assert_contains "$unit_text" 'Before=network-pre.target' 'firewall persistence unit starts too late'
pass 'firewall parsing, rendering, persistence and friendly show'

# Transaction fixtures must live inside the fixed-path contract, otherwise the
# transaction layer rejects them before exercising rollback semantics.
mkdir -p "$INFRA_ETC_DIR"
sample="$INFRA_ETC_DIR/smoke-sample.conf"; printf 'before\n' >"$sample"
txn_begin smoke-rollback; txn_write_file "$sample" 0600 <<<'after'; txn_rollback
grep -Fxq before "$sample" || fail 'transaction rollback'
TXN_OUTCOME=none; TXN_PATHS=(); txn_begin smoke-commit; txn_write_file "$sample" 0600 <<<'committed'; txn_commit; txn_rollback
grep -Fxq committed "$sample" || fail 'committed transaction must not rollback'
pass 'transaction rollback and commit boundary'

restore_file="$INFRA_ETC_DIR/restore.conf"
printf 'original\n' >"$restore_file"
TXN_OUTCOME=none; TXN_PATHS=(); txn_begin restore-source; source_txn="$TXN_ID"
txn_write_file "$restore_file" 0600 <<<'changed'
txn_commit
[[ $(cat "$restore_file") == changed ]] || fail 'restore fixture write'
TXN_OUTCOME=none; TXN_PATHS=(); txn_restore_id "$source_txn" >/dev/null
[[ $(cat "$restore_file") == original ]] || fail 'transaction restore did not restore original'
[[ $TXN_ID != "$source_txn" && $TXN_OUTCOME == committed ]] || fail 'restore did not create a reversible transaction'

bad_txn="${source_txn}-bad"
cp -a "$INFRA_BACKUP_DIR/transactions/$source_txn" "$INFRA_BACKUP_DIR/transactions/$bad_txn"
bad_key="$(find "$INFRA_BACKUP_DIR/transactions/$bad_txn/files" -name '*.path.b64' -printf '%f\n' | sed 's/\.path\.b64$//' | head -n1)"
rm -f "$INFRA_BACKUP_DIR/transactions/$bad_txn/files/$bad_key.data"
printf 'must-stay\n' >"$restore_file"
TXN_OUTCOME=none; TXN_PATHS=()
if txn_restore_id "$bad_txn" >/dev/null 2>&1; then fail 'corrupt transaction restore succeeded'; fi
[[ $(cat "$restore_file") == must-stay ]] || fail 'corrupt transaction deleted current target before validation'
pass 'transaction restore prevalidation and reversibility'

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
NETWORK_PROC_SYS="$fake_proc"
network_apply_sysctl
NETWORK_PROC_SYS=/proc/sys
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

# Regression: read-only commands must work for a normal user and must not be
# gated on creating /var/lib/infra-node. Enforcing directory creation at startup
# broke `version` for non-root users in v1.6.3 development (found on real Debian).
ver_out="$(
  set +u
  INFRA_LOG_DIR="$TMP/ro/log" INFRA_STATE_DIR="$TMP/ro/state" INFRA_BACKUP_DIR="$TMP/ro/backup" \
    bash "$ROOT/bin/infra-node" version 2>&1
)" || fail 'version command failed with relocated (writable) state dirs'
grep -Fq "$INFRA_VERSION" <<<"$ver_out" || fail 'version output missing the version string'

# Now force an unwritable target so core_init's mkdir fails.
if [[ $(id -u) -eq 0 ]]; then
  ro_probe="$TMP/ro-root-probe"
  install -d -m 0555 "$ro_probe"
  ro_root_out="$(INFRA_TEST_MODE=1 INFRA_LOG_DIR="$ro_probe/log" INFRA_STATE_DIR="$ro_probe/a" \
    INFRA_BACKUP_DIR="$ro_probe/b" bash "$ROOT/bin/infra-node" version 2>&1)" \
    || fail 'version must still work when the state tree cannot be created'
  grep -Fq "$INFRA_VERSION" <<<"$ro_root_out" || fail 'version output missing under unwritable state'
else
  ro_out="$(INFRA_TEST_MODE=1 INFRA_LOG_DIR=/proc/nonexistent/log INFRA_STATE_DIR=/proc/nonexistent/state \
    INFRA_BACKUP_DIR=/proc/nonexistent/backup bash "$ROOT/bin/infra-node" version 2>&1)" \
    || fail 'version must still work when the state tree cannot be created'
  grep -Fq "$INFRA_VERSION" <<<"$ro_out" || fail 'version output missing under unwritable state'
fi

# And a write command must fail loudly rather than silently doing nothing.
if bash -c '
  set -Eeuo pipefail
  source "$0/config/defaults.env"
  source "$0/lib/ui.sh"; source "$0/lib/core.sh"; source "$0/lib/transaction.sh"
  INFRA_TEST_MODE=1
  INFRA_ETC_DIR=/proc/nonexistent/etc
  INFRA_STATE_DIR=/proc/nonexistent/state
  INFRA_LOG_DIR=/proc/nonexistent/log
  INFRA_BACKUP_DIR=/proc/nonexistent/backup
  ui_detect; core_init t
  txn_begin t
  txn_write_file /proc/nonexistent/etc/x 0644 <<<y
' "$ROOT" >/dev/null 2>&1; then
  fail 'write into an uncreatable directory must not report success'
fi
pass 'read-only commands survive an unwritable state tree; writes fail loudly'
grep -A8 -F "if ui_confirm '立即部署节点基础设施？' yes; then" "$ROOT/bootstrap.sh"   | grep -Fq 'core_release_lock' || fail 'bootstrap handoff does not release lock'
if ! command -v flock >/dev/null 2>&1; then
  # The install preflight runs this suite with a minimal PATH; flock is a declared
  # dependency of the product, so its absence here is an environment gap, not a bug.
  printf 'SKIP lock re-acquire assertion (flock unavailable)\n'
else
  LOCK_TEST_STATE="$TMP/lock-state"
  INFRA_STATE_DIR="$LOCK_TEST_STATE"
  core_acquire_lock
  core_release_lock
  (
    CORE_LOCK_FD=''
    core_acquire_lock
    core_release_lock
  ) || fail 'lock cannot be reacquired after handoff release'
fi
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
# NTFS does not persist POSIX mode bits, so a local Windows run sets
# INFRA_SMOKE_SKIP_MODES=1. CI never sets it.
if [[ ${INFRA_SMOKE_SKIP_MODES:-0} -eq 1 ]]; then
  printf 'SKIP permission-bit audit (INFRA_SMOKE_SKIP_MODES=1)\n'
else
  mode_file="$TMP/mode-test"
  printf 'x\n' >"$mode_file"
  chmod 0444 "$mode_file"
  AUDIT_WARNINGS=0
  audit_file_mode "$mode_file" 600 >/dev/null
  ((AUDIT_WARNINGS == 1)) || fail 'audit accepted group/other-readable mode 0444 under max 0600'
fi
pass 'permission-bit audit'

# --- Transaction path contract (P0-2) -----------------------------------------
# `backup restore` deletes paths recorded inside the backup directory. Those paths
# must stay inside the fixed-path contract, otherwise a corrupt or tampered
# transaction can `rm -rf` arbitrary targets as root.
[[ $(txn_allowed_paths | wc -l) -ge 5 ]] || fail 'transaction contract is empty'
txn_path_allowed '/etc/sysctl.d/99-infra-node.conf' || fail 'contract rejected sysctl path'
txn_path_allowed "$INFRA_ETC_DIR/firewall.nft" || fail 'contract rejected INFRA_ETC_DIR path'
txn_path_allowed '/usr/local/libexec/infra-node-firewall-apply' || fail 'contract rejected firewall helper path'
if txn_path_allowed '/etc/passwd'; then fail 'contract accepted /etc/passwd'; fi
# `..` must be normalized before matching; this cannot sneak past the contract.
if txn_path_allowed '/usr/local/libexec/../../etc/passwd'; then fail 'contract accepted a .. escape'; fi
if txn_path_allowed 'relative/path'; then fail 'contract accepted a relative path'; fi
if txn_path_allowed '/etc'; then fail 'contract accepted a bare ancestor directory'; fi
if txn_path_allowed '/etc/sysctl.d-evil/x'; then fail 'contract matched a non-component prefix'; fi
pass 'transaction path contract'

# An out-of-contract entry must abort the whole restore before anything is deleted.
escape_txn_src="$TMP/escape-src"
escape_key="$(printf '%s' '/tmp/infra-node-escape-target' | sha256sum | awk '{print $1}')"
mkdir -p "$escape_txn_src/files"
printf 'TYPE=file\nMODE=600\n' >"$escape_txn_src/files/$escape_key.meta"
printf '%s' '/tmp/infra-node-escape-target' | base64 -w0 >"$escape_txn_src/files/$escape_key.path.b64"
printf 'pwned\n' >"$escape_txn_src/files/$escape_key.data"
mkdir -p "$INFRA_BACKUP_DIR/transactions"
cp -a "$escape_txn_src" "$INFRA_BACKUP_DIR/transactions/escape-txn"
escape_target="$TMP/escape-target"
printf 'must-survive\n' >"$escape_target"
if txn_restore_id escape-txn >/dev/null 2>&1; then fail 'out-of-contract restore was accepted'; fi
[[ -f $escape_target ]] || fail 'out-of-contract restore deleted the target'
[[ $(cat "$escape_target") == must-survive ]] || fail 'out-of-contract restore modified the target'
pass 'transaction restore refuses out-of-contract paths'

# --- Dry-run must not mutate anything (P0-1) ----------------------------------
dry_marker="$INFRA_ETC_DIR/dry-run-target"
printf 'original\n' >"$dry_marker"
dry_before="$(sha256sum "$dry_marker" | awk '{print $1}')"
INFRA_DRY_RUN=1
txn_write_file "$dry_marker" 0600 <<<'dry-run-must-not-write'
[[ $(sha256sum "$dry_marker" | awk '{print $1}') == "$dry_before" ]] || fail 'dry-run wrote a file'
dry_dir="$TMP/dry-run-dir/deeper"
INFRA_ETC_DIR="$dry_dir" INFRA_STATE_DIR="$dry_dir" INFRA_BACKUP_DIR="$dry_dir" INFRA_LOG_DIR="$dry_dir"
base_prepare_directories
[[ ! -e $dry_dir ]] || fail 'dry-run created directories'
# shellcheck disable=SC1091
source "$ROOT/config/defaults.env"
INFRA_ETC_DIR="$TMP/etc"

# Swap: the fstab edit is the dangerous part — a stale entry breaks the next boot.
network_fstub="$TMP/dry-fstab"
printf '/dev/vda1 / ext4 defaults 0 1\n' >"$network_fstub"
NETWORK_FSTAB_PATH="$network_fstub"
NETWORK_SWAP_PATH="$TMP/dry-swapfile"
network_swap_is_active() { return 1; }
swapon() { printf 'unexpected swapon call\n' >&2; return 0; }
platform_mem_mb() { printf '256\n'; }
network_configure_swap yes
[[ ! -e $NETWORK_SWAP_PATH ]] || fail 'dry-run created a swap file'
grep -Fq 'dry-swapfile' "$network_fstub" && fail 'dry-run modified /etc/fstab'
unset -f swapon platform_mem_mb
INFRA_DRY_RUN=0
pass 'dry-run performs no writes'

# The dry-run gate must be evaluated BEFORE the test-mode short-circuit. If test
# mode won, the safety gate could never be exercised by this suite and the
# "dry-run performs no writes" test above would be silently vacuous.
# Scoped to network_configure_swap: other functions legitimately test the two
# flags in the opposite order.
swap_body="$(sed -n '/^network_configure_swap()/,/^}/p' "$ROOT/lib/modules/network.sh")"
dry_line="$(printf '%s\n' "$swap_body" | grep -n 'core_is_dry_run' | head -n1 | cut -d: -f1)"
test_mode_line="$(printf '%s\n' "$swap_body" | grep -n 'INFRA_TEST_MODE:-0' | head -n1 | cut -d: -f1)"
[[ -n $dry_line ]] || fail 'network_configure_swap lost its dry-run gate'
[[ -n $test_mode_line && $dry_line -lt $test_mode_line ]] || fail 'dry-run gate is shadowed by the test-mode short-circuit in network_configure_swap'
pass 'dry-run gate precedes test-mode short-circuit'

# A tree that fails its own preflight must never be swapped in.
# Runs in a SEPARATE process (tests/lib/git-gate.sh): a `( ... ) || rc=$?` wrapper
# suppresses errexit for the entire subshell, which would make the gate look broken
# even when it works. Verified on real Debian 13 via WSL.
gate_tree="$TMP/gate-tree"
mkdir -p "$gate_tree" "$TMP/gate-parent"
tar -C "$ROOT" --exclude='./.git' --exclude='./dist' --exclude='./docs' -cf - . | tar -C "$gate_tree" -xf -
gate_rc=0
bash "$ROOT/tests/lib/git-gate.sh" "$ROOT" "$gate_tree" "$TMP/gate-parent" >/dev/null 2>&1 || gate_rc=$?
((gate_rc != 0)) || fail 'install succeeded despite a failing preflight'
[[ ! -e $TMP/gate-parent/opt/infra-node/bin/infra-node ]] || fail 'install swapped in a tree that failed its own preflight'
pass 'failing preflight aborts the install'

# --- Proxy drop-in path (resource limits silently did nothing) ----------------
[[ $(proxy_dropin_path xray.service) == '/etc/systemd/system/xray.d/50-infra-node.conf' ]] || fail 'proxy drop-in path is wrong'
[[ $(proxy_dropin_path sing-box.service) == '/etc/systemd/system/sing-box.d/50-infra-node.conf' ]] || fail 'proxy drop-in path mishandles a dashed unit'
# Regression: `"${unit}.d"` with unit=xray.service yields xray.service.service.d,
# a directory systemd never reads, so the resource limits silently did nothing.
[[ $(proxy_dropin_path xray.service) != *'.service.service.d'* ]] || fail 'proxy drop-in reintroduced the double .service suffix'
pass 'proxy drop-in directory path'

# --- Firewall rollback respects the confirmed/committed boundary (P1-2) -------
# firewall_runtime_rollback short-circuits under INFRA_TEST_MODE so a test can
# never touch a live table; lift it for this block only.
saved_test_mode="${INFRA_TEST_MODE:-0}"
unset INFRA_TEST_MODE
FIREWALL_ROLLBACK_SCRIPT="$TMP/fw-rollback.sh"
printf '#!/usr/bin/env bash\nprintf "rolled-back\\n" >>"%s"\n' "$TMP/fw-rollback.log" >"$FIREWALL_ROLLBACK_SCRIPT"
chmod 0755 "$FIREWALL_ROLLBACK_SCRIPT"
firewall_cancel_rollback() { :; }
TXN_OUTCOME=committed; FIREWALL_APPLIED=1; FIREWALL_CONFIRMED=0
firewall_runtime_rollback
[[ ! -e $TMP/fw-rollback.log ]] || fail 'firewall rolled back after the transaction committed'
TXN_OUTCOME=none; FIREWALL_APPLIED=1; FIREWALL_CONFIRMED=0
firewall_runtime_rollback
[[ -s $TMP/fw-rollback.log ]] || fail 'firewall did not roll back an unconfirmed change'
: >"$TMP/fw-rollback.log"
# Confirmed by the user: a later failure must not undo what they approved.
TXN_OUTCOME=none; FIREWALL_APPLIED=1; FIREWALL_CONFIRMED=1
firewall_runtime_rollback
[[ ! -s $TMP/fw-rollback.log ]] || fail 'firewall reverted rules the user had already confirmed'
# A failure that never applied runtime rules must not touch the live table.
TXN_OUTCOME=none; FIREWALL_APPLIED=0; FIREWALL_CONFIRMED=0
firewall_runtime_rollback
[[ ! -s $TMP/fw-rollback.log ]] || fail 'firewall rolled back without ever applying'
firewall_restore_snapshot_now() { printf 'snapshot-restored\n' >>"$TMP/fw-disable.log"; }
firewall_disable_runtime_rollback
[[ -s $TMP/fw-disable.log ]] || fail 'firewall disable rollback did not restore the previous state'
FIREWALL_APPLIED=0; FIREWALL_CONFIRMED=0
TXN_OUTCOME=none
INFRA_TEST_MODE="$saved_test_mode"
pass 'firewall rollback honors confirmed and committed boundaries'

# Git-Bash mis-resolves repo paths containing spaces, so a local Windows run sets
# INFRA_SMOKE_SKIP_SYNTAX=1; the Makefile 'syntax' target covers this in CI.
if [[ ${INFRA_SMOKE_SKIP_SYNTAX:-0} -eq 1 ]]; then
  printf 'SKIP trailing bash -n loop (INFRA_SMOKE_SKIP_SYNTAX=1)\n'
else
  for file in "$ROOT"/bootstrap.sh "$ROOT"/proxy-vps-foundation.sh "$ROOT"/bin/infra-node "$ROOT"/lib/*.sh "$ROOT"/lib/modules/*.sh "$ROOT"/tests/smoke.sh; do bash -n "$file" || fail "bash syntax ${file#"$ROOT"/}"; done
fi
pass 'Bash syntax'

printf 'Smoke tests passed.\n'
