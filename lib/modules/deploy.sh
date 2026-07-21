#!/usr/bin/env bash

deploy_write_state() {
  txn_begin 'deployment state'
  txn_write_file "$INFRA_STATE_DIR/deploy.env" 0600 <<EOF_STATE
PROFILE=$ASSESS_PROFILE
DEPLOYED_AT=$(core_now)
VERSION=$INFRA_VERSION
EOF_STATE
}

deploy_run() {
  local profile="${1:-auto}" swap="${2:-auto}" security_updates="${3:-no}" proxy_units="${4:-auto}" restart_proxy="${5:-no}"
  core_require_root || return; core_acquire_lock || return; platform_detect_all || return; platform_require_free_space 160 || return
  assessment_choose_profile "$profile" >/dev/null
  assessment_show "$ASSESS_PROFILE"
  txn_begin 'full deployment'
  base_apply "$security_updates"
  network_apply "$swap"
  proxy_apply "$proxy_units" "$restart_proxy"
  core_run_step '记录部署状态' deploy_write_state
  txn_commit
  network_commit_runtime
  ui_ok '节点基础设施部署完成；未安装或配置任何代理程序。'
}
