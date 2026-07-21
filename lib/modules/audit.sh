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
  [[ -d $INFRA_INSTALL_DIR ]] && audit_ok '安装目录存在' || audit_error '安装目录不存在'
  [[ -r $INFRA_INSTALL_DIR/CHECKSUMS.sha256 ]] && (cd "$INFRA_INSTALL_DIR" && sha256sum --strict -c CHECKSUMS.sha256 >/dev/null 2>&1) && audit_ok '安装文件摘要一致' || audit_error '安装文件摘要缺失或不一致'
  audit_file_mode "$INFRA_LOG_DIR/infra-node.log" 600
  audit_file_mode "$INFRA_ETC_DIR/firewall.nft" 600
  if [[ -r /etc/sysctl.d/99-infra-node.conf ]]; then
    grep -Eq '(^|[.])swappiness|tcp_keepalive|ip_local_port_range|tcp_fastopen|rmem_max|wmem_max' /etc/sysctl.d/99-infra-node.conf && audit_error '发现禁止的高侵入网络参数' || audit_ok '未发现高侵入网络参数'
  else
    audit_warn '网络配置尚未部署'
  fi
  if platform_has_systemd; then
    systemctl is-active --quiet systemd-timesyncd.service && audit_ok '时间同步服务活动' || audit_warn 'systemd-timesyncd 未活动或由其他服务接管'
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
  for cmd in bash awk sed grep find sha256sum flock timeout; do command -v "$cmd" >/dev/null 2>&1 && audit_ok "命令可用：$cmd" || { audit_error "命令缺失：$cmd"; rc=1; }; done
  platform_detect_all || rc=1
  [[ -w $INFRA_LOG_DIR || ${INFRA_TEST_MODE:-0} -eq 1 ]] && audit_ok '日志目录可写' || { audit_error '日志目录不可写'; rc=1; }
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && audit_ok '可读取 TCP 拥塞控制能力' || audit_warn '无法读取 TCP 拥塞控制能力'
  return "$rc"
}
