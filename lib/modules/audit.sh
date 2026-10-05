#!/usr/bin/env bash

AUDIT_WARNINGS=0
AUDIT_ERRORS=0

audit_ok() { printf 'OK    %s\n' "$*"; }
audit_warn() { printf 'WARN  %s\n' "$*"; AUDIT_WARNINGS=$((AUDIT_WARNINGS+1)); }
audit_error() { printf 'ERROR %s\n' "$*"; AUDIT_ERRORS=$((AUDIT_ERRORS+1)); }

audit_file_mode() {
  local file="$1" max="$2" mode mode_value max_value
  [[ -e $file ]] || return 0
  mode="$(stat -c %a "$file" 2>/dev/null || echo invalid)"
  if [[ $mode =~ ^[0-7]{3,4}$ && $max =~ ^[0-7]{3,4}$ ]]; then
    mode_value=$((8#$mode)); max_value=$((8#$max))
    # 只允许 max 中已声明的权限位；不能用十进制大小比较 Unix mode。
    if (( (mode_value & ~max_value) == 0 )); then
      audit_ok "$file 权限为 $mode"
    else
      audit_warn "$file 权限偏宽：$mode"
    fi
  else
    audit_warn "$file 权限无法解析：$mode"
  fi
}

audit_run() {
  AUDIT_WARNINGS=0; AUDIT_ERRORS=0
  ui_section 'Infra-node 审计'
  if [[ -d $INFRA_INSTALL_DIR ]]; then audit_ok '安装目录存在'; else audit_error '安装目录不存在'; fi
  local required missing=0
  for required in VERSION bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh config/defaults.env; do
    if [[ -f $INFRA_INSTALL_DIR/$required && ! -L $INFRA_INSTALL_DIR/$required ]]; then :; else
      audit_error "安装文件缺失或类型异常：$required"; missing=1
    fi
  done
  ((missing == 1)) || audit_ok '安装目录结构完整'
  audit_file_mode "$INFRA_LOG_DIR/infra-node.log" 600
  audit_file_mode "$INFRA_ETC_DIR/firewall.nft" 600
  # Honour the module-level path so the audit inspects the file that was actually written.
  local sysctl_file="${NETWORK_SYSCTL_PATH:-/etc/sysctl.d/99-infra-node.conf}"
  if [[ -r $sysctl_file ]]; then
    # Forbidden: settings that weaken security or destabilise the host. Buffer
    # ceilings and tcp_fastopen are deliberately NOT here — v1.6.3 sets them on
    # purpose for proxy throughput (see docs/05-网络性能方案.md).
    if grep -Eq '(^|[.])swappiness|tcp_keepalive|tcp_ecn|tcp_tw_recycle|accept_source_route = 1|accept_redirects = 1' "$sysctl_file"; then
      audit_error '发现禁止的高风险网络参数'
    else
      audit_ok '未发现高风险网络参数'
    fi
  else
    audit_warn '网络配置尚未部署'
  fi
  if platform_has_systemd; then
    if systemctl is-active --quiet systemd-timesyncd.service; then
      audit_ok '时间同步服务活动'
    else
      audit_warn 'systemd-timesyncd 未活动或由其他服务接管'
    fi
  fi
  printf '\n结果：%d 个错误，%d 个警告。\n' "$AUDIT_ERRORS" "$AUDIT_WARNINGS"
  ((AUDIT_ERRORS==0))
}

status_run() {
  platform_detect_all; assessment_collect
  ui_section 'Infra-node 状态'
  ui_kv '版本' "$INFRA_VERSION"
  ui_kv '系统' "$OS_PRETTY_NAME"
  ui_kv '配置档位' "$(awk -F= '$1=="PROFILE"{print $2}' "$INFRA_STATE_DIR/deploy.env" 2>/dev/null || echo 未部署)"
  ui_kv '网络配置' "$([[ -r /etc/sysctl.d/99-infra-node.conf ]] && echo 已写入 || echo 未写入)"
  ui_kv '防火墙' "$(command -v nft >/dev/null 2>&1 && nft list table inet infra_node_filter >/dev/null 2>&1 && echo 已启用 || echo 未启用)"
  ui_kv '最近部署' "$(awk -F= '$1=="DEPLOYED_AT"{sub(/^[^=]*=/,"");print}' "$INFRA_STATE_DIR/deploy.env" 2>/dev/null || echo 无)"
  if platform_has_systemd; then ui_section '已发现代理服务（只读）'; proxy_status || true; fi
}

doctor_run() {
  local rc=0
  ui_section '环境诊断'
  for cmd in bash awk sed grep find flock timeout; do
    if command -v "$cmd" >/dev/null 2>&1; then
      audit_ok "命令可用：$cmd"
    else
      audit_error "命令缺失：$cmd"; rc=1
    fi
  done
  platform_detect_all || rc=1
  if [[ -w $INFRA_LOG_DIR || ${INFRA_TEST_MODE:-0} -eq 1 ]]; then
    audit_ok '日志目录可写'
  else
    audit_error '日志目录不可写'; rc=1
  fi
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
    audit_ok '可读取 TCP 拥塞控制能力'
  else
    audit_warn '无法读取 TCP 拥塞控制能力'
  fi
  return "$rc"
}
