#!/usr/bin/env bash

base_install_packages() {
  packages_install ca-certificates curl iproute2 procps util-linux nftables
}

base_configure_timesync() {
  platform_has_systemd || { ui_warn '未检测到 systemd，跳过时间同步服务设置。'; return 0; }
  if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
    core_dry_run_cmd systemctl enable --now systemd-timesyncd.service
  elif command -v timedatectl >/dev/null 2>&1; then
    core_dry_run_cmd timedatectl set-ntp true || ui_warn '系统未提供可自动启用的 NTP 服务。'
  fi
}

base_configure_journald() {
  local path=/etc/systemd/journald.conf.d/50-infra-node.conf max_use=128M keep_free=128M
  case "${ASSESS_PROFILE:-balanced}" in
    minimal) max_use=64M; keep_free=64M ;;
    performance) max_use=256M; keep_free=256M ;;
  esac
  txn_begin 'journald limits'
  txn_write_file "$path" 0644 <<EOF_JOURNAL
# Managed by Infra-node. Storage mode intentionally remains system-owned.
[Journal]
SystemMaxUse=$max_use
RuntimeMaxUse=$max_use
SystemKeepFree=$keep_free
MaxRetentionSec=14day
Compress=yes
EOF_JOURNAL
  if platform_has_systemd; then core_dry_run_cmd systemctl try-restart systemd-journald.service || ui_warn 'journald 重载失败，配置会在下次启动时生效。'; fi
}

base_configure_security_updates() {
  local enabled="${1:-no}" path=/etc/apt/apt.conf.d/52infra-node-unattended
  [[ $enabled == yes ]] || { ui_info '未启用自动安全更新。'; return 0; }
  packages_install unattended-upgrades
  txn_begin 'security updates'
  txn_write_file "$path" 0644 <<'EOF_UPDATES'
// Managed by Infra-node. Security origins only; no automatic reboot.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
EOF_UPDATES
}

base_prepare_directories() {
  install -d -m 0755 "$INFRA_ETC_DIR" "$INFRA_STATE_DIR" "$INFRA_BACKUP_DIR"
  install -d -m 0700 "$INFRA_LOG_DIR"
}

base_apply() {
  local security_updates="${1:-no}"
  core_run_step '安装基础依赖' base_install_packages
  core_run_step '准备固定目录' base_prepare_directories
  core_run_step '配置时间同步' base_configure_timesync
  core_run_step '限制系统日志占用' base_configure_journald
  core_run_step '配置安全更新策略' base_configure_security_updates "$security_updates"
}
