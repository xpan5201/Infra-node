#!/usr/bin/env bash

NETWORK_SYSCTL_PATH=/etc/sysctl.d/99-infra-node.conf
NETWORK_RUNTIME_SNAPSHOT=''
NETWORK_SWAP_CREATED=0
NETWORK_SWAP_PATH=/swapfile.infra-node

network_bbr_available() {
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control
}

network_build_sysctl() {
  local profile="${1:-balanced}" backlog=4096 somax=4096
  case "$profile" in
    minimal) backlog=2048; somax=2048 ;;
    performance) backlog=8192; somax=8192 ;;
  esac
  cat <<EOF_SYSCTL
# Managed by Infra-node. Conservative host-level tuning only.
net.core.somaxconn = $somax
net.core.netdev_max_backlog = $backlog
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
fs.file-max = 1048576
EOF_SYSCTL
  if network_bbr_available; then
    printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr'
  fi
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
  local key value rc=0
  [[ ${INFRA_TEST_MODE:-0} -eq 1 || ${INFRA_DRY_RUN:-0} -eq 1 ]] && return 0
  while IFS='=' read -r key value; do
    key="${key## }"; key="${key%% }"; value="${value## }"; value="${value%% }"
    [[ -n $key && $key != \#* ]] || continue
    sysctl -w "$key=$value" >/dev/null || { ui_warn "内核拒绝参数：$key"; rc=1; }
  done <"$NETWORK_SYSCTL_PATH"
  return "$rc"
}

network_apply_sysctl() {
  network_capture_runtime
  core_register_failure_hook network_restore_runtime
  txn_begin 'network sysctl'
  txn_write_file "$NETWORK_SYSCTL_PATH" 0644 < <(network_build_sysctl "${ASSESS_PROFILE:-balanced}")
  if ! network_apply_sysctl_runtime; then
    core_die '部分网络参数应用失败，已触发运行时与文件回滚。'
    return 1
  fi
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
  NETWORK_SWAP_CREATED=0
}

network_configure_swap() {
  local policy="${1:-auto}" mem size_mb fstab=/etc/fstab
  if [[ $policy != auto && $policy != yes && $policy != no ]]; then core_die "Swap 策略无效：$policy"; return 1; fi
  [[ $policy != no ]] || { ui_info '按配置跳过 Swap。'; return 0; }
  swapon --noheadings --show=NAME 2>/dev/null | grep -q . && { ui_info '系统已有活动 Swap，保持不变。'; return 0; }
  mem="$(platform_mem_mb)"
  [[ $policy == yes || $mem -lt 1024 ]] || { ui_info '内存充足，自动策略不创建 Swap。'; return 0; }
  size_mb=512; (( mem < 512 )) && size_mb=768
  if [[ ${INFRA_TEST_MODE:-0} -eq 1 ]]; then ui_info "测试模式：计划创建 ${size_mb} MiB Swap。"; return 0; fi
  txn_begin 'swap file'; txn_snapshot "$NETWORK_SWAP_PATH"; txn_snapshot "$fstab"
  core_register_failure_hook network_rollback_swap
  if command -v fallocate >/dev/null 2>&1; then fallocate -l "${size_mb}M" "$NETWORK_SWAP_PATH"; else dd if=/dev/zero of="$NETWORK_SWAP_PATH" bs=1M count="$size_mb" status=none; fi
  chmod 0600 "$NETWORK_SWAP_PATH"; mkswap "$NETWORK_SWAP_PATH" >/dev/null; swapon "$NETWORK_SWAP_PATH"; NETWORK_SWAP_CREATED=1
  grep -Fq "$NETWORK_SWAP_PATH none swap sw 0 0" "$fstab" 2>/dev/null || printf '%s\n' "$NETWORK_SWAP_PATH none swap sw 0 0" >>"$fstab"
  # Keep the swap rollback hook until the full deployment commits.
}

network_commit_runtime() {
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
