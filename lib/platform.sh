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
  local required_mb="$1" available probe="${INFRA_INSTALL_DIR:-/opt/infra-node}"
  [[ $required_mb =~ ^[0-9]+$ ]] || core_die '磁盘空间阈值无效。'
  # 安装目录在首次运行时通常尚不存在。向上寻找最近的现有父目录，
  # 否则 df 会失败并让关键的容量预检被静默跳过。
  while [[ ! -e $probe && $probe != / ]]; do probe="$(dirname -- "$probe")"; done
  [[ -e $probe ]] || probe=/
  available="$(df -Pm -- "$probe" 2>/dev/null | awk 'NR==2{print $4}' || true)"
  [[ $available =~ ^[0-9]+$ ]] || { ui_warn "无法读取 ${probe} 的可用空间，跳过容量预检。"; return 0; }
  (( available >= required_mb )) || core_die "可用磁盘空间不足：至少需要 ${required_mb} MiB，当前约 ${available} MiB。"
}

platform_has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }
platform_mem_mb() { awk '/MemTotal/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0; }
platform_cpu_count() { nproc 2>/dev/null || echo 1; }
platform_disk_free_mb() { df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }
