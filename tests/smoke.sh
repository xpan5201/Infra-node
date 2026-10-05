#!/usr/bin/env bash
# This harness deliberately sets module-level globals and replaces helpers
# (sysctl, modinfo, modprobe, platform_mem_mb, ...) with stubs that the sourced
# libraries call indirectly, and it sources them through a computed path. A static
# analyser cannot follow any of that, so these checks are disabled for the whole
# file rather than sprinkled over ~30 individual sites:
#   SC2034 unused variable        - globals are read by the sourced libraries
#   SC1090/SC1091 non-constant source
#   SC2317 unreachable command    - the stubbed helpers are invoked via the libs
#   SC2329 unused function        - same; SC2317's successor in newer shellcheck
#   SC2016 single-quoted expansion- intentional literals in assertions
# shellcheck disable=SC2034,SC1090,SC1091,SC2317,SC2329,SC2016
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Own the working directory instead of inheriting the caller's. This suite is also
# run by the install preflight as an unprivileged user, and a CWD it cannot read
# (e.g. /root, where a root shell starts) makes every find/sort fail with
# "Failed to restore initial working directory".
cd -- "$ROOT"
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
# pass them against emulated regular files.
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
# Assert the port-range policy through its pure predicate rather than by stubbing
# `sysctl`: the preflight smoke run executes with a cleared environment, where a
# stubbed shell function does not exist, so a stub-based assertion silently reads
# the real host value there and turns host-dependent.
network_ports_need_widening '32768	60999' && fail 'already-wide ephemeral range reported as needing widening'
network_ports_need_widening '44620	48715' || fail 'narrow ephemeral range not detected'
# A wide span starting low must also be left alone (span, not low bound, is the test).
network_ports_need_widening '1024	65535'  && fail 'wide low-starting range reported as needing widening'
network_ports_need_widening ''             || fail 'unreadable range should trigger widening'
network_ports_need_widening 'garbage'      || fail 'malformed range should trigger widening'
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

# The probe must agree with the host's actual ephemeral range: widen only a
# genuinely narrow one. This is an integration assertion on purpose — the decision
# inputs are covered by the pure predicate above, so this only checks the wiring.
if network_ports_need_widening "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)"; then
  ports="$(network_ports_config)" || fail 'narrow ephemeral range was not widened'
  assert_contains "$ports" 'net.ipv4.ip_local_port_range = 10240 65535' 'port range widening output wrong'
else
  network_ports_config && fail 'already-wide ephemeral range was rewritten'
fi
pass 'ephemeral port range widened only when narrow'

# Regression for the silent-BBR bug: a host where tcp_bbr exists as an unloaded
# module must trigger modprobe + persistence, not a silent cubic fallback.
#
# Two facts shape how this is stubbed, both learned the hard way in CI:
#   * the preflight smoke run executes with `env -i` and a fixed PATH, so a PATH
#     shim is NOT reachable there — override the library's own predicate instead;
#   * function overrides survive because that run sources these same libraries.
# Only `modprobe` itself stays a PATH shim; when it is unreachable the test is
# skipped explicitly rather than failing on an environment quirk.
bbr_dir="$TMP/bbr"
bbr_bin="$TMP/bbr-bin"
mkdir -p "$bbr_dir/modules-load.d" "$bbr_dir/proc/net/ipv4" "$bbr_bin"
printf 'reno cubic\n' >"$bbr_dir/proc/net/ipv4/tcp_available_congestion_control"
NETWORK_MODULES_LOAD_DIR="$bbr_dir/modules-load.d"
# NETWORK_PROC_SYS is a plain variable, but network_bbr_available was stubbed out
# with a hardcoded /proc path above, so re-point it at the synthetic kernel too.
network_bbr_available() {
  [[ -r $NETWORK_PROC_SYS/net/ipv4/tcp_available_congestion_control ]] \
    && grep -qw bbr "$NETWORK_PROC_SYS/net/ipv4/tcp_available_congestion_control"
}
bbr_loaded="$TMP/bbr-loaded"
cat >"$bbr_bin/modprobe" <<EOF_MODPROBE
#!/bin/sh
printf 'reno cubic bbr\n' >"$bbr_dir/proc/net/ipv4/tcp_available_congestion_control"
: >"$bbr_loaded"
exit 0
EOF_MODPROBE
chmod 0755 "$bbr_bin/modprobe"
PATH="$bbr_bin:$PATH"
# The kernel ships tcp_bbr as a module (that is what makes the bug possible).
network_bbr_module_present() { return 0; }
NETWORK_PROC_SYS="$bbr_dir/proc"
network_bbr_available && fail 'bbr reported available before the module was loaded'
if command -v modprobe >/dev/null 2>&1; then
  network_ensure_bbr_module || fail 'tcp_bbr module was not loaded although it is present'
  [[ -e $bbr_loaded ]] || fail 'modprobe was never invoked'
else
  # The preflight smoke run uses a fixed PATH that may not contain modprobe, so the
  # shim cannot execute there. Apply the effect the module load would have, so the
  # bbr-available assertions below still run instead of being skipped silently.
  printf 'SKIP live modprobe invocation (not reachable in this environment)\n'
  printf 'reno cubic bbr\n' >"$bbr_dir/proc/net/ipv4/tcp_available_congestion_control"
fi
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
network_bbr_module_present() { return 1; }
printf 'reno cubic\n' >"$bbr_dir/proc/net/ipv4/tcp_available_congestion_control"
nosys="$(network_report_bbr_state 2>&1)"
assert_contains "$nosys" '未提供 BBR' 'missing explicit no-BBR report'
none_text="$(network_build_sysctl balanced)"
assert_not_contains "$none_text" 'tcp_congestion_control = bbr' 'bbr written although unsupported'
PATH="${PATH#"$bbr_bin":}"
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

# Regression: status_run hardcoded /etc/sysctl.d/99-infra-node.conf while audit_run
# honoured NETWORK_SYSCTL_PATH, so the two commands could report on different files.
# The path now has exactly one source of truth, audit_sysctl_file().
_prev_sysctl_path="$NETWORK_SYSCTL_PATH"
NETWORK_SYSCTL_PATH="$TMP/seam.conf"
[[ $(audit_sysctl_file) == "$TMP/seam.conf" ]] || fail 'audit_sysctl_file ignored NETWORK_SYSCTL_PATH'
[[ $(grep -c '/etc/sysctl.d/99-infra-node.conf' "$ROOT/lib/modules/audit.sh") -eq 1 ]] \
  || fail 'the sysctl path is hardcoded again outside audit_sysctl_file'
NETWORK_SYSCTL_PATH="$_prev_sysctl_path"
pass 'sysctl path has one source of truth for status and audit'

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
# INFRA_SMOKE_SKIP_MODES=1.
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

# --- swap policy decisions (the part that can actually go wrong) ---------------
# The real `swapon` call cannot be exercised everywhere (the WSL2 kernel rejects
# swapfiles outright), but the decisions that cause real damage — creating swap on
# a machine that does not need it, and leaving a dangling /etc/fstab entry — are
# pure logic and are covered here.
network_swap_policy_valid auto || fail 'policy auto rejected'
network_swap_policy_valid yes  || fail 'policy yes rejected'
network_swap_policy_valid no   || fail 'policy no rejected'
network_swap_policy_valid bogus && fail 'invalid swap policy accepted'
network_swap_policy_valid ''    && fail 'empty swap policy accepted'

# network_swap_should_create returns 0 (true) when swap SHOULD be created.
network_swap_should_create no 256     && fail 'policy no still wanted to create swap'
network_swap_should_create yes 16384  || fail 'policy yes refused to create swap'
network_swap_should_create auto 1023  || fail 'auto should create swap below 1 GiB'
network_swap_should_create auto 1024  && fail 'auto must not create swap at exactly 1 GiB'
network_swap_should_create auto 16384 && fail 'auto must not create swap on a large host'
network_swap_should_create auto ''    || fail 'unreadable memory should still favour creating swap'
network_swap_should_create bogus 128  && fail 'invalid policy must not create swap'

[[ $(network_swap_size_mb 256) == 768 ]] || fail 'small host should get the larger swap file'
[[ $(network_swap_size_mb 511) == 768 ]] || fail 'boundary 511 MiB should get 768'
[[ $(network_swap_size_mb 512) == 512 ]] || fail 'boundary 512 MiB should get 512'
[[ $(network_swap_size_mb 4096) == 512 ]] || fail 'large host should get the default size'
# Unreadable memory is treated as "very small", which pairs with
# network_swap_should_create's fallback of creating swap on an unknown host.
[[ $(network_swap_size_mb '') == 768 ]] || fail 'unreadable memory should take the small-host path'
pass 'swap policy decisions'

# fstab must gain exactly one entry, and only when it is missing.
swap_fstab="$TMP/swap-fstab"
printf '/dev/vda1 / ext4 defaults 0 1\n' >"$swap_fstab"
NETWORK_FSTAB_PATH="$swap_fstab"
NETWORK_SWAP_PATH="/swapfile.infra-node"
rendered="$(network_fstab_with_swap "$swap_fstab")"
[[ $(printf '%s\n' "$rendered" | grep -c '^/swapfile.infra-node none swap sw 0 0$') == 1 ]] || fail 'fstab rendering must add exactly one swap line'
[[ $(printf '%s\n' "$rendered" | grep -c '^/dev/vda1') == 1 ]] || fail 'fstab rendering dropped the original entry'
# The guard that prevents a second write once the line is present.
printf '%s\n' "$rendered" >"$swap_fstab"
grep -Fqx "$NETWORK_SWAP_PATH none swap sw 0 0" "$swap_fstab" \
  || fail 'committed fstab should now contain the exact swap line'
# An unreadable/absent fstab still yields a usable file.
absent_render="$(network_fstab_with_swap "$TMP/does-not-exist")"
[[ $absent_render == '/swapfile.infra-node none swap sw 0 0' ]] || fail 'missing fstab was not handled'
pass 'swap fstab rendering and idempotency guard'

# Rollback removes the swapfile but must NOT touch fstab: the fstab edit belongs to
# the enclosing transaction, and two hooks writing one file is how a dangling entry
# survives to break the next boot.
rollback_swap="$TMP/rollback-swapfile"
printf 'swapdata\n' >"$rollback_swap"
NETWORK_SWAP_PATH="$rollback_swap"
NETWORK_SWAP_CREATED=1
rollback_fstab="$TMP/rollback-fstab"
printf '%s\n' "$rendered" >"$rollback_fstab"
NETWORK_FSTAB_PATH="$rollback_fstab"
before_fstab="$(cat "$rollback_fstab")"
swapoff() { return 0; }
network_rollback_swap
[[ ! -e $rollback_swap ]] || fail 'rollback left the swapfile behind'
[[ $(cat "$rollback_fstab") == "$before_fstab" ]] || fail 'rollback must not edit fstab itself'
(( NETWORK_SWAP_CREATED == 0 )) || fail 'rollback did not clear the created flag'
# A committed transaction must not be rolled back at all.
NETWORK_SWAP_CREATED=1
printf 'swapdata\n' >"$rollback_swap"
TXN_OUTCOME=committed
network_rollback_swap
[[ -e $rollback_swap ]] || fail 'committed swap was rolled back'
TXN_OUTCOME=none
NETWORK_SWAP_CREATED=0
rm -f "$rollback_swap"
unset -f swapoff
pass 'swap rollback leaves fstab to the transaction'

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
# The full unit name keeps its type suffix: the drop-in directory for
# xray.service is xray.service.d, NOT xray.d. Determined empirically on real
# systemd 257 (Debian 13) — a drop-in placed in xray.d/ is never read, and every
# directory the distribution ships is named <unit>.service.d. The assertion that
# used to live here encoded the opposite, which is how v1.6.3 turned a correct
# path into a broken one. Evidence: _local/verification/dropin-probe.out.txt
[[ $(proxy_dropin_path xray.service) == '/etc/systemd/system/xray.service.d/50-infra-node.conf' ]] || fail 'proxy drop-in path is wrong'
[[ $(proxy_dropin_path sing-box.service) == '/etc/systemd/system/sing-box.service.d/50-infra-node.conf' ]] || fail 'proxy drop-in path mishandles a dashed unit'
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
# INFRA_SMOKE_SKIP_SYNTAX=1; the Makefile 'syntax' target covers it there.
if [[ ${INFRA_SMOKE_SKIP_SYNTAX:-0} -eq 1 ]]; then
  printf 'SKIP trailing bash -n loop (INFRA_SMOKE_SKIP_SYNTAX=1)\n'
else
  for file in "$ROOT"/bootstrap.sh "$ROOT"/proxy-vps-foundation.sh "$ROOT"/bin/infra-node "$ROOT"/lib/*.sh "$ROOT"/lib/modules/*.sh "$ROOT"/tests/smoke.sh; do bash -n "$file" || fail "bash syntax ${file#"$ROOT"/}"; done
fi
pass 'Bash syntax'

# Entry points must be committed with the executable bit. A fresh checkout on Linux
# gives a 100644 shell script "Permission denied" as soon as make runs it; this went
# unnoticed from v1.6.1 onward because the working copy happened to have +x.
# Asserted on git's recorded mode rather than the filesystem, since NTFS cannot
# represent it; a Windows shim skips via INFRA_SMOKE_SKIP_MODES, and a Linux run
# performs the real check.
if [[ ${INFRA_SMOKE_SKIP_MODES:-0} -eq 1 ]]; then
  printf 'SKIP git mode check (INFRA_SMOKE_SKIP_MODES=1)\n'
elif command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r entry; do
    mode="${entry%% *}"
    path="${entry##*$'\t'}"
    [[ $mode == 100755 ]] || fail "committed without the executable bit (mode $mode): $path"
  done < <(git -C "$ROOT" ls-files --stage -- bootstrap.sh proxy-vps-foundation.sh bin/infra-node \
             tests/smoke.sh tests/integration-install.sh)
  # And they must really be runnable as checked out.
  for path in bootstrap.sh proxy-vps-foundation.sh bin/infra-node tests/smoke.sh; do
    [[ -x $ROOT/$path ]] || fail "checked-out entry point is not executable: $path"
  done
  pass 'entry points are committed executable'
else
  printf 'SKIP git mode check (not a git checkout)\n'
fi

# --- self-update: version comparison, channel, drift, rollback ----------------
# Deliberately last: the channel tests stub update_git_with_timeout and
# update_latest_tag, and nothing after this point depends on the real ones.

case "$(update_version_cmp 1.6.3 1.6.10)" in -1) ;; *) fail 'version compare mis-sorted 1.6.3 vs 1.6.10' ;; esac
case "$(update_version_cmp 1.6.10 1.6.3)" in 1) ;; *) fail 'version compare mis-sorted 1.6.10 vs 1.6.3' ;; esac
case "$(update_version_cmp v1.6.3 1.6.3)" in 0) ;; *) fail 'version compare rejected a leading v' ;; esac
case "$(update_version_cmp 1.6.4-rc1 1.6.4)" in 0) ;; *) fail 'a pre-release suffix should collapse onto its release' ;; esac
case "$(update_version_cmp nonsense 1.6.3)" in '?') ;; *) fail 'an unparseable version should report ?' ;; esac
pass 'self-update version comparison'

update_git_with_timeout() {
  printf '%s\n' 'aaa refs/tags/v1.0.0' 'bbb refs/tags/v1.10.0' 'ccc refs/tags/v1.9.0' 'ddd refs/tags/nope'
}
[[ $(update_latest_tag 'https://example.test/x.git') == v1.10.0 ]] \
  || fail 'update_latest_tag did not pick the highest version (lexicographic sort?)'
update_git_with_timeout() { printf '%s\n' 'aaa refs/heads/main'; }
if update_latest_tag 'https://example.test/x.git' >/dev/null; then fail 'update_latest_tag should fail when no version tag exists'; fi
pass 'latest release tag resolution'

update_latest_tag() { printf '%s\n' 'v9.9.9'; }
[[ $(update_resolve_ref '' tag 'https://example.test/x.git' main) == v9.9.9 ]] || fail 'channel=tag did not resolve to the newest tag'
[[ $(update_resolve_ref '' main 'https://example.test/x.git' main) == main ]] || fail 'channel=main did not use the recorded ref'
[[ $(update_resolve_ref develop '' 'https://example.test/x.git' main) == develop ]] || fail 'an explicit ref must win over the channel'
update_latest_tag() { return 1; }
[[ $(update_resolve_ref '' tag 'https://example.test/x.git' main 2>/dev/null) == main ]] \
  || fail 'an unreachable tag list must fall back to the recorded ref, not abort'
if update_resolve_ref '' bogus 'https://example.test/x.git' main >/dev/null 2>&1; then fail 'an unknown channel must be rejected'; fi
pass 'update channel resolution'

# `self-update --apply` runs deploy_run from inside self-update, so the same lock
# is acquired twice. flock belongs to the open file description, so without the
# re-entrancy guard the second acquire blocks against this very process.
# Start from "not held" via core_release_lock rather than assigning CORE_LOCK_FD:
# touching a global the earlier subshell test also assigns is what makes shellcheck
# emit its SC2030/SC2031 pair.
INFRA_STATE_DIR="$TMP/lock-state"; mkdir -p "$INFRA_STATE_DIR"
core_release_lock
core_acquire_lock || fail 'first lock acquire failed'
core_acquire_lock || fail 'lock is not re-entrant: self-update --apply would deadlock against itself'
core_release_lock
pass 'install lock is re-entrant for nested commands'

_state_saved="${INFRA_STATE_DIR:-}"; _install_saved="${INFRA_INSTALL_DIR:-}"
INFRA_STATE_DIR="$TMP/drift/state"; INFRA_INSTALL_DIR="$TMP/drift/install"
mkdir -p "$INFRA_STATE_DIR" "$INFRA_INSTALL_DIR"; printf '1.6.3\n' >"$INFRA_INSTALL_DIR/VERSION"
if update_report_config_drift >/dev/null 2>&1; then fail 'a missing deploy.env must be reported'; fi
printf 'PROFILE=balanced\nVERSION=1.6.3\n' >"$INFRA_STATE_DIR/deploy.env"
update_report_config_drift >/dev/null 2>&1 || fail 'matching versions must report no drift'
printf 'PROFILE=balanced\nVERSION=1.6.2\n' >"$INFRA_STATE_DIR/deploy.env"
if update_report_config_drift >/dev/null 2>&1; then fail 'a stale deploy.env must be reported as drift'; fi
[[ $(update_deployed_profile) == balanced ]] || fail 'update_deployed_profile did not read deploy.env'
pass 'config drift detection (upgrade without re-deploy)'
INFRA_STATE_DIR="$_state_saved"

_parent="$TMP/rollback/opt"; INFRA_INSTALL_DIR="$_parent/infra-node"
mkdir -p "$INFRA_INSTALL_DIR" "$_parent/infra-node.backup.20260101T000000Z-1-00001" \
         "$_parent/infra-node.backup.20260102T000000Z-1-00002" "$_parent/unrelated"
_cands="$(update_backup_candidates | tr '\n' ' ')"
[[ $_cands == 'infra-node.backup.20260102T000000Z-1-00002 infra-node.backup.20260101T000000Z-1-00001 ' ]] \
  || fail "update_backup_candidates listed the wrong set: ${_cands}"
pass 'rollback candidate listing (newest first, unrelated dirs excluded)'

_etc_saved="${INFRA_ETC_DIR:-}"; INFRA_ETC_DIR="$TMP/snap/etc"; mkdir -p "$INFRA_ETC_DIR" "$TMP/snap/outgoing"
printf 'URL=https://example.test/x.git\nREF=main\n' >"$INFRA_ETC_DIR/repo.env"
update_snapshot_repo_metadata "$TMP/snap/outgoing"
[[ -r "$TMP/snap/outgoing/.infra-node-repo.env" ]] \
  || fail 'the outgoing tree got no copy of repo.env; a rollback would keep stale metadata'
pass 'rollback keeps repository metadata with the outgoing tree'

# Regression: when the local checkout cannot serve as the install source, the
# reason must be stated. Falling back to a network clone in silence is how an
# end-to-end run installed a different commit than the one it was pointed at
# (root could not read the repo and nothing said so).
mkdir -p "$TMP/not-a-repo/.git"
_fallback_reason="$(update_local_source_reason "$TMP/not-a-repo" 'https://example.test/x.git' main)"
[[ $_fallback_reason == *'无法读取'* ]] \
  || fail "local-source fallback gave no usable reason: ${_fallback_reason}"
mkdir -p "$TMP/plain-dir"
[[ $(update_local_source_reason "$TMP/plain-dir" 'https://example.test/x.git' main) == '不是 Git 检出' ]] \
  || fail 'a directory without .git should be reported as such'
pass 'local source fallback explains itself'
INFRA_ETC_DIR="$_etc_saved"; INFRA_INSTALL_DIR="$_install_saved"

# --- batch C: adaptive decisions ---------------------------------------------

# Containers share the host kernel, so kernel-level tuning has to be refused
# rather than half-applied. OS_VIRT was previously detected and only displayed.
_saved_virt="${OS_VIRT:-none}"
OS_VIRT=docker;  platform_is_container || fail 'docker must count as a container'
OS_VIRT=openvz;  platform_is_container || fail 'openvz must count as a container'
OS_VIRT=kvm;     if platform_is_container; then fail 'a KVM guest must not count as a container'; fi
OS_VIRT=none;    if platform_is_container; then fail 'bare metal must not count as a container'; fi
OS_VIRT=wsl;     platform_is_wsl || fail 'wsl should be recognised as WSL'
OS_VIRT="$_saved_virt"
pass 'virtualisation classification'

# Creating a swap file without checking free space can fill a small disk, which
# takes the node down far harder than having no swap at all. Deploy only asked
# for 220 MiB, so a 768 MiB swap file was reachable on an almost-full disk.
network_swap_space_sufficient 512 4096 || fail '512 MiB swap should fit in 4 GiB free'
if network_swap_space_sufficient 512 600; then fail '512 MiB of swap must not pass with only 600 MiB free'; fi
if network_swap_space_sufficient 768 900; then fail 'the reserved headroom was ignored'; fi
network_swap_space_sufficient 512 '' || fail 'an unreadable free-space value must not block creation'
pass 'swap space guard leaves headroom'

# Never lower a limit the operator already raised: the port-range rule already
# follows "widen only", the drop-in did not.
[[ $(proxy_choose_nofile 262144 1048576) == 1048576 ]] || fail 'a higher existing LimitNOFILE was lowered'
[[ $(proxy_choose_nofile 262144 1024) == 262144 ]] || fail 'a lower existing LimitNOFILE was not raised'
[[ $(proxy_choose_nofile 262144 infinity) == infinity ]] || fail 'LimitNOFILE=infinity was replaced by a finite value'
[[ $(proxy_choose_nofile 262144 '') == 262144 ]] || fail 'an unreadable LimitNOFILE should fall back to the profile value'
pass 'proxy drop-in only ever raises limits'

# Assign at top level and read inside $( ) — exporting inside a command
# substitution makes shellcheck emit its SC2030/SC2031 pair, and the value only
# needs to be visible to the read either way.
_oom_saved="${INFRA_PROXY_OOM_SCORE_ADJUST:-}"
[[ $(proxy_limits_for_profile balanced | awk '{print $3}') == 100 ]] \
  || fail 'the default OOMScoreAdjust should stay 100'
INFRA_PROXY_OOM_SCORE_ADJUST=-500
[[ $(proxy_limits_for_profile balanced | awk '{print $3}') == -500 ]] \
  || fail 'INFRA_PROXY_OOM_SCORE_ADJUST was ignored'
INFRA_PROXY_OOM_SCORE_ADJUST=bogus
[[ $(proxy_limits_for_profile balanced | awk '{print $3}') == 100 ]] \
  || fail 'a bogus OOMScoreAdjust should fall back to 100'
if [[ -n $_oom_saved ]]; then INFRA_PROXY_OOM_SCORE_ADJUST="$_oom_saved"; else unset INFRA_PROXY_OOM_SCORE_ADJUST; fi
pass 'proxy OOM score is configurable'

# Symmetry with the firewall, which refuses to take over when UFW, firewalld or a
# foreign nftables chain is present. sysctl had no equivalent check.
_saved_dir="$NETWORK_SYSCTL_DIR"; _saved_conf="$NETWORK_SYSCTL_CONF"
NETWORK_SYSCTL_DIR="$TMP/sysctl-d"; NETWORK_SYSCTL_CONF="$TMP/sysctl-d/absent.conf"
mkdir -p "$NETWORK_SYSCTL_DIR"
printf 'net.core.somaxconn = 1\n# a comment\nunrelated.key = 2\n' >"$NETWORK_SYSCTL_DIR/50-someone-else.conf"
printf 'net.core.somaxconn = 3\n' >"$NETWORK_SYSCTL_DIR/99-infra-node.conf"
_conf="$(network_find_conflicts "$NETWORK_SYSCTL_DIR/99-infra-node.conf" "$(printf 'net.core.somaxconn\n')")"
[[ $_conf == *'50-someone-else.conf: net.core.somaxconn'* ]] || fail "conflict scan missed an overlap: ${_conf}"
[[ $_conf != *'99-infra-node.conf'* ]] || fail 'conflict scan reported our own file'
[[ $_conf != *'unrelated.key'* ]] || fail 'conflict scan reported a key we do not manage'
_conf="$(network_find_conflicts "$NETWORK_SYSCTL_DIR/99-infra-node.conf" "$(printf 'unrelated.key\n')")"
[[ $_conf != *'somaxconn'* ]] || fail 'conflict scan ignored the managed-key list'
# network_managed_keys must list the keys we actually write, but a naive call is
# host-dependent in two ways: an earlier test unsets platform_mem_mb, and a Windows
# Git-Bash has no /proc/sys at all — so every key would be filtered out as
# "unsupported by this kernel". Pin both seams so the assertion means the same thing
# everywhere. (The version without pinning passed on Debian and failed on Git-Bash.)
mkdir -p "$TMP/mk-proc/net/core"
: >"$TMP/mk-proc/net/core/somaxconn"
: >"$TMP/mk-proc/net/core/netdev_max_backlog"
_proc_saved="$NETWORK_PROC_SYS"
_mem_saved="$(declare -f platform_mem_mb || true)"
NETWORK_PROC_SYS="$TMP/mk-proc"
platform_mem_mb() { printf '2048\n'; }
_keys="$(network_managed_keys balanced)"
NETWORK_PROC_SYS="$_proc_saved"
if [[ -n $_mem_saved ]]; then eval "$_mem_saved"; else unset -f platform_mem_mb; fi
[[ $_keys == *'net.core.somaxconn'* ]] || fail "network_managed_keys missed a key we write: ${_keys}"
[[ $_keys != *'='* ]] || fail 'network_managed_keys returned whole lines instead of key names'
pass 'sysctl conflict scan'
NETWORK_SYSCTL_DIR="$_saved_dir"; NETWORK_SYSCTL_CONF="$_saved_conf"

printf 'Smoke tests passed.\n'
