#!/usr/bin/env bash

tui_panel() {
  local choice
  while true; do
    ui_banner
    cat <<'EOF_MENU'

1) 一键部署基础设施
2) 查看状态
3) 环境诊断
4) 安全审计
5) 防火墙状态
6) 按需网络测试
7) 备份事务列表
0) 退出
EOF_MENU
    read -r -p '请选择: ' choice || return 0
    case "$choice" in
      1) deploy_run auto auto no auto no ;;
      2) status_run ;;
      3) doctor_run ;;
      4) audit_run ;;
      5) firewall_status ;;
      6) experience_run ;;
      7) txn_list ;;
      0) return 0 ;;
      *) ui_warn '无效选择。' ;;
    esac
  done
}
