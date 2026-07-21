#!/usr/bin/env bash

FIREWALL_TABLE='inet infra_node_filter'
FIREWALL_CONFIG=/etc/infra-node/firewall.nft
FIREWALL_ROLLBACK_SCRIPT=/run/infra-node/firewall-rollback.sh
FIREWALL_ROLLBACK_UNIT=infra-node-firewall-rollback
FIREWALL_TCP_PORTS=()
FIREWALL_UDP_PORTS=()
FIREWALL_CONFIRMED=0
FIREWALL_PREVIOUS_SNAPSHOT=''

firewall_add_port() {
  local proto="$1" port="$2" existing
  core_valid_port "$port" || core_die "非法端口：$port"
  local -n target="FIREWALL_${proto^^}_PORTS"
  for existing in "${target[@]}"; do [[ $existing == "$port" ]] && return 0; done
  target+=("$port")
}

firewall_parse_ports() {
  local proto="$1" csv="${2:-}" port
  [[ -n $csv ]] || return 0
  IFS=',' read -r -a _fw_ports <<<"$csv"
  for port in "${_fw_ports[@]}"; do port="${port//[[:space:]]/}"; [[ -n $port ]] && firewall_add_port "$proto" "$port"; done
}

firewall_detect_ssh_ports() {
  local port
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <(
      ss -H -lntp 2>/dev/null | awk '$0 ~ /sshd/ {addr=$4; sub(/^.*:/,"",addr); gsub(/\[|\]/,"",addr); if(addr~/^[0-9]+$/) print addr}' | sort -un
    )
  fi
  if ((${#FIREWALL_TCP_PORTS[@]}==0)) && command -v sshd >/dev/null 2>&1; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <(sshd -T 2>/dev/null | awk '$1=="port" && $2~/^[0-9]+$/ {print $2}')
  fi
  if ((${#FIREWALL_TCP_PORTS[@]}==0)) && platform_has_systemd && systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <(systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | sort -un)
  fi
  if ((${#FIREWALL_TCP_PORTS[@]}==0)) && [[ -r /etc/ssh/sshd_config ]]; then
    while IFS= read -r port; do core_valid_port "$port" && firewall_add_port tcp "$port"; done < <(awk 'tolower($1)=="port" && $2~/^[0-9]+$/ {print $2}' /etc/ssh/sshd_config)
  fi
  ((${#FIREWALL_TCP_PORTS[@]})) || firewall_add_port tcp 22
}

firewall_ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; }
firewall_firewalld_active() { command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qx running; }

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
  command -v nft >/dev/null 2>&1 || core_die 'nft 命令不存在。'
  firewall_ufw_active && core_die '检测到活动 UFW，拒绝重复接管防火墙。'
  firewall_firewalld_active && core_die '检测到活动 firewalld，拒绝重复接管防火墙。'
  if firewall_external_input_chain_exists; then core_die '检测到其他 nftables input 基链，拒绝叠加。'; else
    local rc=$?; ((rc==1)) || core_die '无法读取当前 nftables 规则，拒绝冒险修改。'
  fi
  platform_has_systemd && command -v systemd-run >/dev/null 2>&1 || core_die '缺少 systemd-run，无法设置自动回滚保护。'
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

firewall_write_rollback() {
  local previous="$1"
  install -d -m 0700 /run/infra-node
  cat >"$FIREWALL_ROLLBACK_SCRIPT" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -u
nft delete table inet infra_node_filter >/dev/null 2>&1 || true
if [[ -s $(printf '%q' "$previous") ]]; then nft -f $(printf '%q' "$previous") >/dev/null 2>&1 || true; fi
EOF_ROLLBACK
  chmod 0700 "$FIREWALL_ROLLBACK_SCRIPT"
}

firewall_schedule_rollback() {
  systemctl stop "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --quiet --unit="$FIREWALL_ROLLBACK_UNIT" --on-active="${INFRA_FIREWALL_ROLLBACK_SECONDS}s" /bin/bash "$FIREWALL_ROLLBACK_SCRIPT"
}

firewall_cancel_rollback() {
  systemctl stop "$FIREWALL_ROLLBACK_UNIT.timer" "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$FIREWALL_ROLLBACK_UNIT.timer" "$FIREWALL_ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  rm -f -- "$FIREWALL_ROLLBACK_SCRIPT"
}

firewall_runtime_rollback() {
  [[ ${INFRA_TEST_MODE:-0} -eq 1 ]] && return 0
  [[ -x $FIREWALL_ROLLBACK_SCRIPT ]] && /bin/bash "$FIREWALL_ROLLBACK_SCRIPT" || true
  firewall_cancel_rollback
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
}

firewall_apply() {
  local tcp_csv="${1:-}" udp_csv="${2:-}" temp previous
  FIREWALL_TCP_PORTS=(); FIREWALL_UDP_PORTS=()
  firewall_detect_ssh_ports; firewall_parse_ports tcp "$tcp_csv"; firewall_parse_ports udp "$udp_csv"
  if [[ ${INFRA_TEST_MODE:-0} -eq 1 ]]; then firewall_render_rules; return 0; fi
  firewall_preflight
  temp="$(mktemp /run/infra-node-firewall.XXXXXX)"; previous="$(mktemp /run/infra-node-firewall-prev.XXXXXX)"
  core_register_tmp "$temp"; core_register_tmp "$previous"
  firewall_render_rules >"$temp"
  nft -c -f "$temp" || core_die 'nftables 语法预检失败。'
  nft list table inet infra_node_filter >"$previous" 2>/dev/null || : >"$previous"
  FIREWALL_PREVIOUS_SNAPSHOT="$previous"
  firewall_write_rollback "$previous"
  core_register_failure_hook firewall_runtime_rollback
  firewall_schedule_rollback
  nft delete table inet infra_node_filter >/dev/null 2>&1 || true
  nft -f "$temp"
  nft list table inet infra_node_filter >/dev/null 2>&1 || core_die '新防火墙规则未成功加载，等待自动回滚。'
  txn_begin 'firewall config'; txn_write_file "$FIREWALL_CONFIG" 0600 <"$temp"
  ui_warn "防火墙已应用，${INFRA_FIREWALL_ROLLBACK_SECONDS} 秒后会自动回滚，除非确认。"
  if ui_confirm '当前 SSH 连接正常，确认保留防火墙规则？' no; then
    FIREWALL_CONFIRMED=1
    ui_ok '连接确认通过；将在事务提交后取消自动回滚。'
  else
    ui_warn '未确认；立即恢复原规则。'
    return 3
  fi
  rm -f -- "$temp"; core_unregister_tmp "$temp"
}

firewall_disable() {
  core_require_root
  [[ ${INFRA_TEST_MODE:-0} -eq 1 ]] && return 0
  command -v nft >/dev/null 2>&1 && nft delete table inet infra_node_filter >/dev/null 2>&1 || true
  firewall_cancel_rollback
  txn_begin 'disable firewall'; txn_remove "$FIREWALL_CONFIG"
  ui_ok '已删除 Infra-node 自有防火墙表；未修改其他规则。'
}

firewall_status() {
  if command -v nft >/dev/null 2>&1 && nft list table inet infra_node_filter >/dev/null 2>&1; then
    nft list table inet infra_node_filter
  else
    echo 'Infra-node 防火墙未启用。'
  fi
}
