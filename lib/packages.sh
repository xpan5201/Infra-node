#!/usr/bin/env bash

packages_missing() { local p; for p in "$@"; do dpkg-query -W -f='${db:Status-Status}\n' "$p" 2>/dev/null | grep -qx 'installed' || printf '%s\n' "$p"; done; }
packages_install() {
  local missing=() p
  mapfile -t missing < <(packages_missing "$@")
  ((${#missing[@]})) || { ui_info '所需软件包均已安装，跳过 APT 安装。'; return 0; }
  if [[ ${INFRA_TEST_MODE:-0} -eq 1 ]]; then ui_info "测试模式跳过安装：${missing[*]}"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${missing[@]}"
}
