#!/usr/bin/env bash

NETWORK_SYSCTL_PATH=/etc/sysctl.d/99-infra-node.conf
NETWORK_RUNTIME_SNAPSHOT=''
NETWORK_SWAP_CREATED=0
NETWORK_SWAP_PATH=/swapfile.infra-node
NETWORK_FSTAB_PATH=/etc/fstab
# Test seam: mirrors /proc/sys so the support filter can be exercised off-kernel.
NETWORK_PROC_SYS=/proc/sys
# Test seam: where the BBR module-load persistence file goes.
NETWORK_MODULES_LOAD_DIR=/etc/modules-load.d
# Keys this kernel has no knob for. Recorded in a FILE, not a variable: the
# builder always runs inside a command substitution (a subshell), so neither an
# array NOR the file-path variable could be assigned there and reach the caller.
# Hence a fixed, predictable path derived in the parent shell.
NETWORK_SKIPPED_FILE="${TMPDIR:-/tmp}/infra-node-sysctl-skipped.$$"
network_skipped_keys() {
  [[ -s $NETWORK_SKIPPED_FILE ]] || return 0
  cat -- "$NETWORK_SKIPPED_FILE"
}
network_skipped_reset() { : >"$NETWORK_SKIPPED_FILE"; }

network_bbr_available() {
  [[ -r $NETWORK_PROC_SYS/net/ipv4/tcp_available_congestion_control ]] \
    && grep -qw bbr "$NETWORK_PROC_SYS/net/ipv4/tcp_available_congestion_control"
}

# Debian/Ubuntu ship tcp_bbr as a module that is NOT loaded by default, so
# tcp_available_congestion_control lists only "reno cubic" on a fresh host. The
# previous detection simply grepped that list and therefore reported "no BBR"
# and silently configured nothing — the user believed BBR was on while the host
# kept running cubic. Load the module first, then re-check.
network_bbr_module_present() {
  modinfo tcp_bbr >/dev/null 2>&1
}

network_ensure_bbr_module() {
  # Explicit ifs, not `a && return 0`: a bare test as the function's last command
  # can surface a non-zero status to the ERR trap and look like a hard failure.
  if network_bbr_available; then
    return 0
  fi
  if ! network_bbr_module_present; then
    return 1
  fi
  if ! command -v modprobe >/dev/null 2>&1; then
    return 1
  fi
  if [[ ${INFRA_DRY_RUN:-0} -eq 1 ]]; then
    core_dry_run_note 'would load kernel module tcp_bbr'
    return 0
  fi
  modprobe tcp_bbr 2>/dev/null || true
  network_bbr_available
}

# /etc/sysctl.d is applied at boot; if the module is not loaded by then,
# tcp_congestion_control=bbr fails to apply and the host silently stays on cubic.
# Persisting the module is what makes BBR survive a reboot.
network_write_bbr_module_persistence() {
  [[ ${INFRA_TEST_MODE:-0} -eq 1 ]] && return 0
  local path="${NETWORK_MODULES_LOAD_DIR%/}/50-infra-node-bbr.conf"
  txn_begin 'bbr module persistence'
  txn_write_file "$path" 0644 <<'EOF_BBR_MODULE' || return 1
# Managed by Infra-node. Without this, tcp_congestion_control=bbr in
# /etc/sysctl.d/99-infra-node.conf fails to apply on the next boot.
tcp_bbr
EOF_BBR_MODULE
}

# Buffer ceilings are a bandwidth-delay-product knob: too small caps single-stream
# throughput, too large lets unbounded applications hold more memory per socket.
# Scale with installed RAM so a 512 MiB VPS stays safe while a large node gets the
# throughput it is paying for.
network_buffer_max_bytes() {
  local mem
  mem="$(platform_mem_mb)"
  if [[ ! $mem =~ ^[0-9]+$ ]] || (( mem < 1024 )); then
    printf '%s\n' 4194304      # <= 1 GiB: keep the previous conservative value
  elif (( mem < 4096 )); then
    printf '%s\n' 8388608      # 1-4 GiB
  else
    printf '%s\n' 16777216     # >= 4 GiB
  fi
}

# Widen the ephemeral range when the host ships an unusually narrow one (WSL2
# exposed 44620-48715, about 4000 ports). A proxy that opens many outbound
# connections exhausts that and fails with EADDRNOTAVAIL. Never narrows an
# already-wide range, because that could collide with local service ports.
NETWORK_PORT_RANGE_MIN_SPAN=28000

# Pure predicate over a "low<TAB>high" string. Split out from the probe so it can be
# tested by passing a value directly: a stubbed `sysctl` shell function does NOT
# survive into the preflight smoke run (which executes with a cleared environment),
# so a test that relies on stubbing it reads the real host value instead and becomes
# host-dependent — which is exactly how a false failure reached CI.
network_ports_need_widening() {
  local current="${1:-}" low high
  read -r low high <<<"$current"
  if [[ $low =~ ^[0-9]+$ && $high =~ ^[0-9]+$ ]] && (( high - low >= NETWORK_PORT_RANGE_MIN_SPAN )); then
    return 1
  fi
  return 0
}

network_ports_config() {
  if network_ports_need_widening "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || true)"; then
    printf '%s\n' 'net.ipv4.ip_local_port_range = 10240 65535'
    return 0
  fi
  return 1
}

# Drop keys this kernel does not expose. A host with IPv6 disabled at boot
# (ipv6.disable=1) has no /proc/sys/net/ipv6 at all; applying those keys fails,
# and because network_apply_sysctl_runtime() reports any failure, the whole
# deployment used to abort with a misleading "kernel rejected parameter" error.
network_filter_unsupported() {
  local line key rest path
  while IFS= read -r line; do
    if [[ -z $line || $line == \#* ]]; then printf '%s\n' "$line"; continue; fi
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    rest="${line#*=}"
    if [[ -z $key ]]; then printf '%s\n' "$line"; continue; fi
    path="$NETWORK_PROC_SYS/${key//./\/}"
    if [[ -e $path ]]; then
      printf '%s =%s\n' "$key" "$rest"
    else
      printf '%s\n' "$key" >>"$NETWORK_SKIPPED_FILE"
    fi
  done
}

network_build_sysctl() {
  local profile="${1:-balanced}" backlog somax syn_backlog bufsize
  case "$profile" in
    minimal) backlog=2048; somax=2048; syn_backlog=2048 ;;
    performance) backlog=8192; somax=8192; syn_backlog=8192 ;;
    *) backlog=4096; somax=4096; syn_backlog=4096 ;;
  esac
  bufsize="$(network_buffer_max_bytes)"
  # Fresh slate per call; callers must read network_skipped_keys() before the next call.
  : >"$NETWORK_SKIPPED_FILE"
  {
    cat <<EOF_SYSCTL
# Managed by Infra-node. Host-level tuning aimed at proxy throughput and latency.
net.core.somaxconn = $somax
net.core.netdev_max_backlog = $backlog
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
# Proxy sockets are reused heavily; do not fall back to slow start after idle.
net.ipv4.tcp_slow_start_after_idle = 0
# Keep unsent bytes low so forwarded data leaves promptly (lower latency).
net.ipv4.tcp_notsent_lowat = 131072
# Socket buffer ceilings. Raise both ends of auto-tuning with the ceiling.
net.core.rmem_max = $bufsize
net.core.wmem_max = $bufsize
net.ipv4.tcp_rmem = 8192 131072 $bufsize
net.ipv4.tcp_wmem = 4096 16384 $bufsize
# UDP: QUIC / Hysteria / TUIC ride on this and the ~208 KiB default drops packets
# well before a fast link is saturated.
net.core.rmem_default = $bufsize
net.core.wmem_default = $bufsize
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_fastopen = 3
EOF_SYSCTL
    network_ports_config || true
    if network_bbr_available; then
      printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr'
    fi
  } | network_filter_unsupported
}

network_report_bbr_state() {
  if network_bbr_available; then
    ui_ok '拥塞控制：BBR 可用（配合 fq 调度器）。'
    return 0
  fi
  if network_bbr_module_present; then
    ui_warn '本内核未加载 tcp_bbr 模块，已回退 cubic（拥塞控制未启用 BBR）。'
    ui_warn '可手动执行：modprobe tcp_bbr，然后重新运行 infra-node deploy。'
  else
    ui_warn '本内核未提供 BBR（既不在可用列表中，也无 tcp_bbr 模块），保持默认拥塞控制。'
  fi
}

network_report_skipped_keys() {
  local keys
  keys="$(network_skipped_keys | tr '\n' ' ')"
  [[ -n ${keys// /} ]] || return 0
  ui_warn "本内核未提供以下参数，已跳过：${keys% }"
  ui_warn '（例如内核以 ipv6.disable=1 启动时不会有 net.ipv6.* 开关。）'
}

network_capture_runtime() {
  local key value
  NETWORK_RUNTIME_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/infra-node-sysctl.XXXXXX")"
  core_register_tmp "$NETWORK_RUNTIME_SNAPSHOT"
  while IFS='=' read -r key value; do
    key="${key//[[:space:]]/}"
    [[ -n $key && $key != \#* ]] || continue
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    printf '%s=%s\n' "$key" "$value" >>"$NETWORK_RUNTIME_SNAPSHOT"
  done < <(network_build_sysctl "${ASSESS_PROFILE:-balanced}")
  network_report_skipped_keys
}

network_restore_runtime() {
  local key value
  [[ ${TXN_OUTCOME:-none} != committed ]] || return 0
  [[ -r ${NETWORK_RUNTIME_SNAPSHOT:-} ]] || return 0
  while IFS='=' read -r key value; do
    [[ -n $key ]] || continue
    sysctl -w "$key=$value" >/dev/null 2>&1 || true
  done <"$NETWORK_RUNTIME_SNAPSHOT"
}

network_apply_sysctl_runtime() {
  local key value rc=0 path
  [[ ${INFRA_TEST_MODE:-0} -eq 1 || ${INFRA_DRY_RUN:-0} -eq 1 ]] && return 0
  network_skipped_reset
  while IFS='=' read -r key value; do
    key="${key## }"; key="${key%% }"; value="${value## }"; value="${value%% }"
    [[ -n $key && $key != \#* ]] || continue
    path="$NETWORK_PROC_SYS/${key//./\/}"
    # Last line of defence: a knob this kernel does not expose is skipped with a
    # report, not treated as a hard failure. Treating it as failure aborted the
    # whole deployment on hosts that boot with IPv6 disabled.
    if [[ ! -e $path ]]; then
      printf '%s\n' "$key" >>"$NETWORK_SKIPPED_FILE"
      continue
    fi
    if ! sysctl -w "$key=$value" >/dev/null; then
      ui_warn "内核拒绝参数：$key"
      rc=1
    fi
  done <"$NETWORK_SYSCTL_PATH"
  network_report_skipped_keys
  return "$rc"
}

network_apply_sysctl() {
  # Load tcp_bbr before building, so the generated file includes bbr/fq whenever
  # the kernel can actually provide them.
  network_ensure_bbr_module || true
  network_capture_runtime
  core_register_failure_hook network_restore_runtime
  txn_begin 'network sysctl'
  txn_write_file "$NETWORK_SYSCTL_PATH" 0644 < <(network_build_sysctl "${ASSESS_PROFILE:-balanced}") || return 1
  if ! network_apply_sysctl_runtime; then
    core_die '部分网络参数应用失败，已触发运行时与文件回滚。'
    return 1
  fi
  # Persist the module so tcp_congestion_control=bbr still applies after a reboot.
  if network_bbr_available; then
    network_write_bbr_module_persistence || return 1
  fi
  network_report_bbr_state
  # Keep the runtime snapshot registered until the enclosing transaction is
  # committed. A later proxy/base failure must restore both files and live sysctls.
}

network_swap_is_active() {
  if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$NETWORK_SWAP_PATH"; then return 0; fi
  return 1
}

network_rollback_swap() {
  [[ ${TXN_OUTCOME:-none} != committed ]] || return 0
  (( NETWORK_SWAP_CREATED == 1 )) || return 0
  swapoff "$NETWORK_SWAP_PATH" >/dev/null 2>&1 || true
  rm -f -- "$NETWORK_SWAP_PATH"
  # The /etc/fstab edit is owned by the enclosing transaction (written through
  # txn_write_file), so txn_rollback restores it. Never edit fstab here: two
  # independent hooks mutating the same file is how a dangling swap entry
  # survives and breaks the next boot.
  NETWORK_SWAP_CREATED=0
}

# --- swap policy: pure decision helpers ---------------------------------------
# Split out of network_configure_swap() so the decisions can be tested without
# touching the kernel. The real swapon() call cannot be exercised in every test
# environment (the WSL2 kernel rejects swapfiles outright), but the choices that
# actually go wrong — should we create, how big, do we duplicate the fstab entry —
# are all computable and therefore testable.

network_swap_policy_valid() {
  [[ ${1:-} == auto || ${1:-} == yes || ${1:-} == no ]]
}

# auto: only when the host is short on memory. yes: always. no: never.
network_swap_should_create() {
  local policy="${1:-auto}" mem="${2:-0}"
  [[ $mem =~ ^[0-9]+$ ]] || mem=0
  case "$policy" in
    no) return 1 ;;
    yes) return 0 ;;
    auto) (( mem < 1024 )) && return 0; return 1 ;;
    *) return 1 ;;
  esac
}

# Smaller machines get a slightly larger file; they have the least headroom.
network_swap_size_mb() {
  local mem="${1:-0}"
  [[ $mem =~ ^[0-9]+$ ]] || mem=0
  if (( mem < 512 )); then printf 768; else printf 512; fi
}

# True when the host already runs some swap, in which case we leave it alone.
network_swap_present_on_host() {
  if network_swap_is_active; then return 0; fi
  if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then return 0; fi
  return 1
}

network_configure_swap() {
  local policy="${1:-auto}" mem size_mb fstab="$NETWORK_FSTAB_PATH"
  if ! network_swap_policy_valid "$policy"; then core_die "Swap 策略无效：$policy"; return 1; fi
  [[ $policy != no ]] || { ui_info '按配置跳过 Swap。'; return 0; }
  if network_swap_present_on_host; then ui_info '系统已有活动 Swap，保持不变。'; return 0; fi
  mem="$(platform_mem_mb)"
  if ! network_swap_should_create "$policy" "$mem"; then ui_info '内存充足，自动策略不创建 Swap。'; return 0; fi
  size_mb="$(network_swap_size_mb "$mem")"
  # dry-run 优先于测试模式，理由同 firewall_apply：安全闸门必须可测。
  if core_is_dry_run; then
    core_dry_run_note "would create ${size_mb} MiB swap at $NETWORK_SWAP_PATH and add it to $fstab"
    return 0
  fi
  if [[ ${INFRA_TEST_MODE:-0} -eq 1 ]]; then ui_info "测试模式：计划创建 ${size_mb} MiB Swap。"; return 0; fi
  txn_begin 'swap file'; txn_snapshot "$NETWORK_SWAP_PATH" || return 1
  core_register_failure_hook network_rollback_swap
  if command -v fallocate >/dev/null 2>&1; then fallocate -l "${size_mb}M" "$NETWORK_SWAP_PATH"; else dd if=/dev/zero of="$NETWORK_SWAP_PATH" bs=1M count="$size_mb" status=none; fi
  chmod 0600 "$NETWORK_SWAP_PATH"; mkswap "$NETWORK_SWAP_PATH" >/dev/null; swapon "$NETWORK_SWAP_PATH"; NETWORK_SWAP_CREATED=1
  # Route the fstab edit through the transaction so it is snapshotted and
  # restored together with everything else in this deployment.
  if ! grep -Fqx "$NETWORK_SWAP_PATH none swap sw 0 0" "$fstab" 2>/dev/null; then
    txn_write_file "$fstab" 0644 < <(network_fstab_with_swap "$fstab") || return 1
  fi
  # Keep the swap rollback hook until the full deployment commits.
}

network_fstab_with_swap() {
  local fstab="$1"
  # sed 的 '$a\' 是 GNU 扩展，不准；这里只用 POSIX 语义：
  # 原样输出现有内容（若可读），再追加 swap 行。
  [[ -r $fstab ]] && cat -- "$fstab"
  printf '%s\n' "$NETWORK_SWAP_PATH none swap sw 0 0"
}

network_commit_runtime() {
  rm -f -- "$NETWORK_SKIPPED_FILE"
  if [[ -n ${NETWORK_RUNTIME_SNAPSHOT:-} ]]; then
    core_unregister_failure_hook network_restore_runtime
    rm -f -- "$NETWORK_RUNTIME_SNAPSHOT"
    core_unregister_tmp "$NETWORK_RUNTIME_SNAPSHOT"
    NETWORK_RUNTIME_SNAPSHOT=''
  fi
  if (( NETWORK_SWAP_CREATED == 1 )); then
    core_unregister_failure_hook network_rollback_swap
    NETWORK_SWAP_CREATED=0
  fi
}

network_apply() {
  local swap_policy="${1:-auto}"
  core_run_step '应用保守网络参数' network_apply_sysctl
  core_run_step '配置 Swap 策略' network_configure_swap "$swap_policy"
}
