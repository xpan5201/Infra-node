#!/usr/bin/env bash

OS_ID=unknown OS_VERSION_ID=unknown OS_PRETTY_NAME=unknown OS_ARCH=unknown OS_VIRT=unknown

platform_os_value() {
  local key="$1" file="${2:-/etc/os-release}"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "$file" 2>/dev/null || true
}

platform_detect_all() {
  OS_ID="$(platform_os_value ID)"; OS_VERSION_ID="$(platform_os_value VERSION_ID)"; OS_PRETTY_NAME="$(platform_os_value PRETTY_NAME)"
  OS_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  OS_VIRT="$(systemd-detect-virt 2>/dev/null || true)"; [[ -n $OS_VIRT ]] || OS_VIRT=none
  if [[ $OS_ID != debian && $OS_ID != ubuntu && ${INFRA_TEST_MODE:-0} -ne 1 ]]; then
    core_die "仅支持 Debian/Ubuntu，当前为 ${OS_ID}。"
    return 1
  fi
  case "$OS_ARCH" in
    amd64|arm64) ;;
    *)
      if [[ ${INFRA_TEST_MODE:-0} -ne 1 ]]; then core_die "不支持架构：${OS_ARCH}"; return 1; fi
      ;;
  esac
}

platform_require_free_space() {
  local required_mb="$1" available
  available="$(df -Pm "${INFRA_INSTALL_DIR:-/opt}" 2>/dev/null | awk 'NR==2{print $4}' || true)"
  [[ $available =~ ^[0-9]+$ ]] || return 0
  (( available >= required_mb )) || core_die "可用磁盘空间不足：至少需要 ${required_mb} MiB。"
}

platform_has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }
platform_mem_mb() { awk '/MemTotal/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0; }
platform_cpu_count() { nproc 2>/dev/null || echo 1; }
platform_disk_free_mb() { df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }
