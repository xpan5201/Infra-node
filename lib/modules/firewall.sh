#!/usr/bin/env bash

FIREWALL_TABLE='inet infra_node_filter'
FIREWALL_CONFIG=/etc/infra-node/firewall.nft
FIREWALL_HELPER=/usr/local/libexec/infra-node-firewall-apply
FIREWALL_UNIT=/etc/systemd/system/infra-node-firewall.service
FIREWALL_SERVICE=infra-node-firewall.service
FIREWALL_ROLLBACK_SCRIPT=/run/infra-node/firewall-rollback.sh
FIREWALL_ROLLBACK_UNIT=infra-node-firewall-rollback
FIREWALL_TCP_PORTS=()
FIREWALL_UDP_PORTS=()
FIREWALL_CONFIRMED=0
FIREWALL_PREVIOUS_SNAPSHOT=''
FIREWALL_SERVICE_WAS_ENABLED=0
FIREWALL_SERVICE_WAS_ACTIVE=0
FIREWALL_SERVICE_TOUCHED=0

firewall_add_token() {
  local proto="$1" token="$2" existing start end
  local -n target="FIREWALL_${proto^^}_PORTS"
  token="${token//[[:space:]]/}"
  [[ -n $token ]] || return 0
  if [[ $token =~ ^[0-9]+$ ]]; then
    if ! core_valid_port "$token"; then core_die "非法端口：$token"; return 1; fi
    token="$((10#$token))"
  elif [[ $token =~ ^([0-9]+)-([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    if ! core_valid_port "$start" || ! core_valid_port "$end" || ((10#$start > 10#$end)); then
      core_die "非法端口范围：$token"
      return 1
    fi
    token="$((10#$start))-$((10#$end))"
  else
    core_die "非法端口或范围：$token"
    return 1
  fi
  for existing in "${target[@]}"; do [[ $existing == "$token" ]] && return 0; done
  if ((${#target[@]} >= 128)); then core_die '端口条目过多，最多允许 128 项。'; return 1; fi
  target+=("$token")
}

firewall_add_port() { firewall_add_token "$1" "$2"; }

firewall_parse_ports() {
  local proto="$1" csv="${2:-}" token
  [[ -n $csv ]] || return 0
  local -a parsed=()
  IFS=',' read -r -a parsed <<<"$csv"
  for token in "${parsed[@]}"; do firewall_add_token "$proto" "$token" || return; done
}

firewall_detect_ssh_ports() {
  local port
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <(
      { ss -H -lntp 2>/dev/null || true; } | awk '$0 ~ /sshd/ {addr=$4; sub(/^.*:/,"",addr); gsub(/\[|\]/,"",addr); if(addr~/^[0-9]+$/) print addr}' | sort -un
    )
  fi
  if ((${#FIREWALL_TCP_PORTS[@]}==0)) && command -v sshd >/dev/null 2>&1; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <({ sshd -T 2>/dev/null || true; } | awk '$1=="port" && $2~/^[0-9]+$/ {print $2}')
  fi
  if ((${#FIREWALL_TCP_PORTS[@]}==0)) && platform_has_systemd && systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <(
      { systemctl show ssh.socket -p Listen --value 2>/dev/null || true; } \
        | { grep -oE ':[0-9]+' || true; } | tr -d ':' | sort -un
    )
  fi
  if ((${#FIREWALL_TCP_PORTS[@]}==0)) && [[ -r /etc/ssh/sshd_config ]]; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <(awk 'tolower($1)=="port" && $2~/^[0-9]+$/ {print $2}' /etc/ssh/sshd_config)
  fi
  ((${#FIREWALL_TCP_PORTS[@]})) || firewall_add_port tcp 22
}

firewall_ufw_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  if ufw status 2>/dev/null | grep -qi '^Status: active'; then return 0; fi
  return 1
}

firewall_firewalld_active() {
  command -v firewall-cmd >/dev/null 2>&1 || return 1
  if firewall-cmd --state 2>/dev/null | grep -qx running; then return 0; fi
  return 1
}

firewall_external_input_chain_exists() {
  local rules
  rules="$(nft list ruleset 2>/dev/null)" || return 2
  awk '
    /^table[[:space:]]+/ {table=$2 " " $3}
    /hook[[:space:]]+input([[:space:]]|;)/ && table != "inet infra_node_filter" {found=1}
    END {exit found ? 0 : 1}
  ' <<<"$rules"
}

firewall_preflight() {
  if ! command -v nft >/dev/null 2>&1; then core_die 'nft 命令不存在。'; return 1; fi
  if firewall_ufw_active; then core_die '检测到活动 UFW，拒绝重复接管防火墙。'; return 1; fi
  if firewall_firewalld_active; then core_die '检测到活动 firewalld，拒绝重复接管防火墙。'; return 1; fi
  if firewall_external_input_chain_exists; then
    core_die '检测到其他 nftables input 基链，拒绝叠加。'
    return 1
  else
    local rc=$?
    if ((rc != 1)); then core_die '无法读取当前 nftables 规则，拒绝冒险修改。'; return 1; fi
  fi
  if ! platform_has_systemd || ! command -v systemd-run >/dev/null 2>&1; then
    core_die '缺少 systemd-run，无法设置自动回滚保护。'
    return 1
  fi
}

firewall_join_ports() {
  local first=1 port
  for port in "$@"; do
    ((first==1)) || printf ', '
    printf '%s' "$port"
    first=0
  done
}

firewall_render_rules() {
  local tcp udp
  tcp="$(firewall_join_ports "${FIREWALL_TCP_PORTS[@]}")"
  udp="$(firewall_join_ports "${FIREWALL_UDP_PORTS[@]}")"
  cat <<'EOF_HEAD'
table inet infra_node_filter {
  chain input {
    type filter hook input priority filter; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto icmp accept
    meta l4proto ipv6-icmp accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
EOF_HEAD
  [[ -n $tcp ]] && printf '    tcp dport { %s } accept\n' "$tcp"
  [[ -n $udp ]] && printf '    udp dport { %s } accept\n' "$udp"
  cat <<'EOF_TAIL'
    counter drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
  }
  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF_TAIL
}

firewall_render_helper() {
  local nft_bin="$1"
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf 'NFT=%q\n' "$nft_bin"
  printf 'CONFIG=%q\n' "$FIREWALL_CONFIG"
  cat <<'EOF_HELPER'
[[ -r $CONFIG ]] || { printf 'Infra-node firewall config is missing: %s\n' "$CONFIG" >&2; exit 1; }
"$NFT" -c -f "$CONFIG"
"$NFT" delete table inet infra_node_filter >/dev/null 2>&1 || true
exec "$NFT" -f "$CONFIG"
EOF_HELPER
}

firewall_render_unit() {
  cat <<EOF_UNIT
[Unit]
Description=Infra-node owned nftables firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target
ConditionPathExists=$FIREWALL_CONFIG

[Service]
Type=oneshot
ExecStart=$FIREWALL_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

firewall_capture_service_state() {
  FIREWALL_SERVICE_WAS_ENABLED=0
  FIREWALL_SERVICE_WAS_ACTIVE=0
  FIREWALL_SERVICE_TOUCHED=0
  if systemctl is-enabled --quiet "$FIREWALL_SERVICE" 2>/dev/null; then FIREWALL_SERVICE_WAS_ENABLED=1; fi
  if systemctl is-active --quiet "$FIREWALL_SERVICE" 2>/dev/null; then FIREWALL_SERVICE_WAS_ACTIVE=1; fi
}

firewall_restore_service_state() {
  ((FIREWALL_SERVICE_TOUCHED == 1)) || return 0
  systemctl daemon-reload >/dev/null 2>&1 || true
  if ((FIREWALL_SERVICE_WAS_ENABLED == 1)); then
    systemctl enable "$FIREWALL_SERVICE" >/dev/null 2>&1 || true
  else
    systemctl disable "$FIREWALL_SERVICE" >/dev/null 2>&1 || true
  fi
  if ((FIREWALL_SERVICE_WAS_ACTIVE == 1)); then
    systemctl start "$FIREWALL_SERVICE" >/dev/null 2>&1 || true
  else
    systemctl stop "$FIREWALL_SERVICE" >/dev/null 2>&1 || true
  fi
  FIREWALL_SERVICE_TOUCHED=0
}

firewall_write_persistence_files() {
  local nft_bin
  nft_bin="$(command -v nft)" || { core_die '无法定位 nft 可执行文件。'; return 1; }
  txn_write_file "$FIREWALL_HELPER" 0755 < <(firewall_render_helper "$nft_bin") || return
  txn_write_file "$FIREWALL_UNIT" 0644 < <(firewall_render_unit) || return
}

firewall_rollback_pending() {
  systemctl is-active --quiet "$FIREWALL_ROLLBACK_UNIT.timer" 2>/dev/null
}

firewall_enable_persistence() {
  if ! firewall_rollback_pending; then
    core_die '防火墙确认窗口已超时，临时规则可能已经回滚；请重新执行配置。'
    return 1
  fi
  FIREWALL_SERVICE_TOUCHED=1
  systemctl daemon-reload || return
  systemctl enable "$FIREWALL_SERVICE" || return
  systemctl restart "$FIREWALL_SERVICE" || return
  if ! systemctl is-enabled --quiet "$FIREWALL_SERVICE" || ! systemctl is-active --quiet "$FIREWALL_SERVICE"; then
    core_die '防火墙已加载，但开机持久化服务未成功启用。'
    return 1
  fi
}

firewall_write_rollback() {
  local previous="$1" nft_bin="$2"
  install -d -m 0700 /run/infra-node
  cat >"$FIREWALL_ROLLBACK_SCRIPT" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -u
NFT=$(printf '%q' "$nft_bin")
PREVIOUS=$(printf '%q' "$previous")
"\$NFT" delete table inet infra_node_filter >/dev/null 2>&1 || true
if [[ -s \$PREVIOUS ]]; then "\$NFT" -f "\$PREVIOUS" >/dev/null 2>&1 || true; fi
EOF_ROLLBACK
  chmod 0700 "$FIREWALL_ROLLBACK_SCRIPT"
}

firewall_schedule_rollback() {
  systemctl stop "$FIREWALL_ROLLBACK_UNIT.timer" "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$FIREWALL_ROLLBACK_UNIT.timer" "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --quiet --unit="$FIREWALL_ROLLBACK_UNIT" --on-active="${INFRA_FIREWALL_ROLLBACK_SECONDS}s" /bin/bash "$FIREWALL_ROLLBACK_SCRIPT"
}

firewall_cancel_rollback() {
  if platform_has_systemd; then
    systemctl stop "$FIREWALL_ROLLBACK_UNIT.timer" "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
    systemctl reset-failed "$FIREWALL_ROLLBACK_UNIT.timer" "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  fi
  rm -f -- "$FIREWALL_ROLLBACK_SCRIPT"
}

firewall_restore_snapshot_now() {
  command -v nft >/dev/null 2>&1 || return 0
  nft delete table inet infra_node_filter >/dev/null 2>&1 || true
  if [[ -n ${FIREWALL_PREVIOUS_SNAPSHOT:-} && -s $FIREWALL_PREVIOUS_SNAPSHOT ]]; then
    nft -f "$FIREWALL_PREVIOUS_SNAPSHOT" >/dev/null 2>&1 || true
  fi
}

firewall_runtime_rollback() {
  [[ ${TXN_OUTCOME:-none} != committed ]] || return 0
  [[ ${INFRA_TEST_MODE:-0} -eq 1 ]] && return 0
  if [[ -x $FIREWALL_ROLLBACK_SCRIPT ]]; then
    /bin/bash "$FIREWALL_ROLLBACK_SCRIPT" || true
  else
    firewall_restore_snapshot_now
  fi
  firewall_cancel_rollback
  firewall_restore_service_state
}

firewall_finalize() {
  (( FIREWALL_CONFIRMED == 1 )) || return 0
  core_unregister_failure_hook firewall_runtime_rollback
  firewall_cancel_rollback
  if [[ -n ${FIREWALL_PREVIOUS_SNAPSHOT:-} ]]; then
    rm -f -- "$FIREWALL_PREVIOUS_SNAPSHOT"
    core_unregister_tmp "$FIREWALL_PREVIOUS_SNAPSHOT"
  fi
  FIREWALL_PREVIOUS_SNAPSHOT=''
  FIREWALL_CONFIRMED=0
  FIREWALL_SERVICE_TOUCHED=0
}

firewall_configure() {
  local tcp_csv="${1:-}" udp_csv="${2:-}" explicit="${3:-0}"
  if [[ $explicit != 1 && -z $tcp_csv && -z $udp_csv ]]; then
    if [[ ${INFRA_NON_INTERACTIVE:-0} -eq 1 || ! -t 0 ]]; then
      core_die '非交互模式下请使用 --tcp/--udp 指定端口；只保留 SSH 时可传 --tcp "" --udp ""。'
      return 1
    fi
    ui_section '配置主机防火墙'
    ui_info 'SSH 实际监听端口会自动保留，无需手工填写。'
    read -r -p '额外允许的 TCP 端口或范围（逗号分隔，可留空）: ' tcp_csv || return 1
    read -r -p '额外允许的 UDP 端口或范围（逗号分隔，可留空）: ' udp_csv || return 1
  fi
  ui_kv '额外 TCP' "${tcp_csv:-无}"
  ui_kv '额外 UDP' "${udp_csv:-无}"
  firewall_apply "$tcp_csv" "$udp_csv"
}

firewall_apply() {
  local tcp_csv="${1:-}" udp_csv="${2:-}" temp previous nft_bin
  FIREWALL_TCP_PORTS=(); FIREWALL_UDP_PORTS=()
  FIREWALL_CONFIRMED=0
  FIREWALL_PREVIOUS_SNAPSHOT=''
  firewall_detect_ssh_ports || return
  firewall_parse_ports tcp "$tcp_csv" || return
  firewall_parse_ports udp "$udp_csv" || return
  if [[ ${INFRA_TEST_MODE:-0} -eq 1 ]]; then firewall_render_rules; return 0; fi
  firewall_preflight || return
  nft_bin="$(command -v nft)" || { core_die '无法定位 nft 可执行文件。'; return 1; }
  firewall_capture_service_state
  temp="$(mktemp /run/infra-node-firewall.XXXXXX)"
  previous="$(mktemp /run/infra-node-firewall-prev.XXXXXX)"
  core_register_tmp "$temp"; core_register_tmp "$previous"
  firewall_render_rules >"$temp"
  if ! nft -c -f "$temp"; then core_die 'nftables 语法预检失败。'; return 1; fi
  nft list table inet infra_node_filter >"$previous" 2>/dev/null || : >"$previous"
  FIREWALL_PREVIOUS_SNAPSHOT="$previous"
  firewall_write_rollback "$previous" "$nft_bin"
  core_register_failure_hook firewall_runtime_rollback
  firewall_schedule_rollback
  nft delete table inet infra_node_filter >/dev/null 2>&1 || true
  nft -f "$temp"
  if ! nft list table inet infra_node_filter >/dev/null 2>&1; then core_die '新防火墙规则未成功加载，等待自动回滚。'; return 1; fi

  txn_begin 'firewall config'
  txn_write_file "$FIREWALL_CONFIG" 0600 <"$temp" || return
  firewall_write_persistence_files || return
  ui_warn "防火墙已应用，${INFRA_FIREWALL_ROLLBACK_SECONDS} 秒后会自动回滚，除非确认。"
  if ui_confirm '当前 SSH 连接正常，确认保留防火墙规则？' no; then
    firewall_enable_persistence
    FIREWALL_CONFIRMED=1
    ui_ok '连接确认通过；规则将在开机时自动恢复，并在事务提交后取消本次自动回滚。'
  else
    ui_warn '未确认；立即恢复原规则。'
    return 3
  fi
  rm -f -- "$temp"; core_unregister_tmp "$temp"
}

firewall_disable() {
  local previous
  core_require_root || return
  [[ ${INFRA_TEST_MODE:-0} -eq 1 ]] && return 0
  previous="$(mktemp /run/infra-node-firewall-disable-prev.XXXXXX)"
  core_register_tmp "$previous"
  if command -v nft >/dev/null 2>&1; then
    nft list table inet infra_node_filter >"$previous" 2>/dev/null || : >"$previous"
  else
    : >"$previous"
  fi
  FIREWALL_CONFIRMED=0
  FIREWALL_PREVIOUS_SNAPSHOT="$previous"
  firewall_capture_service_state
  core_register_failure_hook firewall_runtime_rollback
  txn_begin 'disable firewall'
  FIREWALL_SERVICE_TOUCHED=1
  # Disable while the unit file still exists, otherwise systemd may leave a
  # dangling wants/ symlink that would reappear after a later reinstall.
  systemctl disable --now "$FIREWALL_SERVICE" >/dev/null 2>&1 || true
  txn_remove "$FIREWALL_CONFIG" || return
  txn_remove "$FIREWALL_HELPER" || return
  txn_remove "$FIREWALL_UNIT" || return
  command -v nft >/dev/null 2>&1 && nft delete table inet infra_node_filter >/dev/null 2>&1 || true
  systemctl daemon-reload || return
  firewall_cancel_rollback
  FIREWALL_CONFIRMED=1
  ui_ok '已删除 Infra-node 自有防火墙表和开机持久化服务；未修改其他规则。'
}

firewall_show() {
  local rules='' persistence='未启用'
  if ! command -v nft >/dev/null 2>&1; then
    ui_info 'nftables 尚未安装，Infra-node 防火墙未启用。'
    return 0
  fi
  if rules="$(nft list table inet infra_node_filter 2>/dev/null)"; then
    printf '%s\n' "$rules"
  else
    ui_info 'Infra-node 防火墙未启用（自有表 inet infra_node_filter 不存在）。'
    [[ -r $FIREWALL_CONFIG ]] && ui_warn "发现持久化配置但运行时表不存在：$FIREWALL_CONFIG"
  fi
  if platform_has_systemd && systemctl is-enabled --quiet "$FIREWALL_SERVICE" 2>/dev/null; then
    persistence='已启用'
    if ! systemctl is-active --quiet "$FIREWALL_SERVICE" 2>/dev/null; then persistence='已启用，但当前服务异常'; fi
  fi
  ui_kv '开机持久化' "$persistence"
  return 0
}

firewall_status() { firewall_show; }
