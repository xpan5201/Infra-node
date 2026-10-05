#!/usr/bin/env bash

# The panel must survive a command that reports failure, otherwise a host with a
# missing tool (no nft, no flock, ...) drops the operator back to the shell and
# looks like a crash. Command-line invocation keeps the raw exit status; only the
# interactive panel absorbs it.
tui_run_safe() {
  local label="$1"; shift
  "$@" || ui_warn "${label}未全部完成；已返回主菜单。"
}

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
      1) tui_run_safe '部署' deploy_run auto auto no auto no ;;
      2) tui_run_safe '查看状态' status_run ;;
      3) tui_run_safe '环境诊断' doctor_run ;;
      4) tui_run_safe '安全审计' audit_run ;;
      5) tui_run_safe '防火墙状态' firewall_status ;;
      6) tui_run_safe '网络测试' experience_run ;;
      7) tui_run_safe '备份列表' txn_list ;;
      0) return 0 ;;
      *) ui_warn '无效选择。' ;;
    esac
  done
}
