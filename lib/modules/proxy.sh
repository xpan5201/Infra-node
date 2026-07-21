#!/usr/bin/env bash

PROXY_KNOWN_UNITS=(xray.service sing-box.service hysteria-server.service hysteria.service tuic.service naive.service shadowsocks-libev.service)

proxy_unit_exists() {
  local unit="$1"
  core_safe_unit "$unit" || return 1
  # 这是一个正常的“存在性探测”，未找到 unit 必须安静返回 1。
  # 将可能返回 1 的管道放进 if 条件，避免 inherit_errexit/ERR trap 在
  # process substitution 中把“未找到”误报成整个部署失败。
  if systemctl list-unit-files "$unit" --no-legend --no-pager 2>/dev/null \
      | awk -v wanted="$unit" '$1 == wanted { found=1 } END { exit found ? 0 : 1 }'; then
    return 0
  fi
  return 1
}

proxy_discover_units() {
  local unit
  platform_has_systemd || return 0
  for unit in "${PROXY_KNOWN_UNITS[@]}"; do
    if proxy_unit_exists "$unit"; then
      printf '%s\n' "$unit"
    fi
  done
}

proxy_limits_for_profile() {
  case "${1:-balanced}" in
    minimal) printf '%s\n' '65536 1024 100' ;;
    performance) printf '%s\n' '524288 8192 100' ;;
    *) printf '%s\n' '262144 4096 100' ;;
  esac
}

proxy_write_dropin() {
  local unit="$1" restart="${2:-no}" nofile tasks oom path values
  core_safe_unit "$unit" || core_die "非法 systemd unit：$unit"
  read -r nofile tasks oom < <(proxy_limits_for_profile "${ASSESS_PROFILE:-balanced}")
  path="/etc/systemd/system/${unit}.d/50-infra-node.conf"
  txn_begin 'proxy resource limits'
  txn_write_file "$path" 0644 <<EOF_DROPIN
# Managed by Infra-node. This file only adjusts process resource limits.
[Service]
LimitNOFILE=$nofile
TasksMax=$tasks
OOMScoreAdjust=$oom
EOF_DROPIN
  if platform_has_systemd; then
    systemctl daemon-reload
    if [[ $restart == yes ]]; then systemctl restart "$unit"; else ui_info "已写入 $unit 资源限制；未重启服务。"; fi
  fi
}

proxy_apply() {
  local units_csv="${1:-auto}" restart="${2:-no}" unit found=0
  [[ $restart == yes || $restart == no ]] || core_die 'restart 参数必须为 yes/no'
  if [[ $units_csv == auto ]]; then
    while IFS= read -r unit; do [[ -n $unit ]] || continue; found=1; core_run_step "适配 $unit" proxy_write_dropin "$unit" "$restart"; done < <(proxy_discover_units)
  else
    IFS=',' read -r -a _proxy_units <<<"$units_csv"
    for unit in "${_proxy_units[@]}"; do
      unit="${unit//[[:space:]]/}"; [[ -n $unit ]] || continue
      proxy_unit_exists "$unit" || core_die "未找到 unit：$unit"
      found=1; core_run_step "适配 $unit" proxy_write_dropin "$unit" "$restart"
    done
  fi
  ((found==1)) || ui_info '未发现已安装的受支持代理服务，不创建任何 drop-in。'
}

proxy_status() {
  local unit
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    printf '%-32s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
  done < <(proxy_discover_units)
}
