#!/usr/bin/env bash

# Detected host facts. Deliberately global: the check that consumes them lives in
# another module, so shellcheck cannot see the read.
# shellcheck disable=SC2034
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

# Container runtimes share the host kernel, so kernel-level network parameters are
# either not writable or would silently change the host — and every other tenant
# on it. Detected so the caller can refuse loudly instead of half-applying.
PLATFORM_CONTAINER_VIRTS=(docker podman lxc lxc-libvirt openvz systemd-nspawn proot)

platform_is_container() {
  local v="${OS_VIRT:-none}" c
  for c in "${PLATFORM_CONTAINER_VIRTS[@]}"; do
    [[ $v == "$c" ]] && return 0
  done
  return 1
}

platform_is_wsl() { [[ ${OS_VIRT:-} == wsl || ${OS_VIRT:-} == microsoft ]]; }

# Free space in MiB on the filesystem holding $1. Walks up to the nearest existing
# parent first, because the target path usually does not exist yet and df would
# otherwise fail — which is how a capacity precheck silently becomes a no-op.
# Returns 1 when the value cannot be read, so callers can choose not to block.
platform_free_mb_at() {
  local probe="${1:-/}" available
  while [[ ! -e $probe && $probe != / ]]; do probe="$(dirname -- "$probe")"; done
  [[ -e $probe ]] || probe=/
  available="$(df -Pm -- "$probe" 2>/dev/null | awk 'NR==2{print $4}' || true)"
  [[ $available =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$available"
}

platform_require_free_space() {
  local required_mb="$1" available probe="${INFRA_INSTALL_DIR:-/opt/infra-node}"
  if [[ ! $required_mb =~ ^[0-9]+$ ]]; then core_die '磁盘空间阈值无效。'; return 1; fi
  if ! available="$(platform_free_mb_at "$probe")"; then
    ui_warn "无法读取 ${probe} 的可用空间，跳过容量预检。"
    return 0
  fi
  if (( available < required_mb )); then core_die "可用磁盘空间不足：至少需要 ${required_mb} MiB，当前约 ${available} MiB。"; return 1; fi
}

platform_has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }
platform_mem_mb() { awk '/MemTotal/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0; }
platform_cpu_count() { nproc 2>/dev/null || echo 1; }
platform_disk_free_mb() { df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }
