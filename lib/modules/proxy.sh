#!/usr/bin/env bash

# 只列具体 unit。xray@.service 这类模板 unit 需要实例名，无法靠猜发现，
# 因此只支持通过 --proxy-units 显式指定。
PROXY_KNOWN_UNITS=(
  xray.service v2ray.service sing-box.service
  hysteria.service hysteria-server.service hysteria2.service
  tuic.service tuic-server.service
  naive.service naiveproxy.service
  shadowsocks-libev.service shadowsocks-rust.service
  trojan.service trojan-go.service
  mieru.service brook.service snell-server.service mtg.service
)
PROXY_SYSTEMD_DIR=/etc/systemd/system

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
  # OOMScoreAdjust is configurable because its default is a deliberate trade-off,
  # not an obvious win: +100 makes the proxy the first thing the kernel kills under
  # memory pressure, which keeps the host (and your SSH session) reachable but
  # takes the service down. On a single-purpose proxy node an operator may prefer
  # a negative value. See README「代理资源限制」。
  local oom="${INFRA_PROXY_OOM_SCORE_ADJUST:-100}"
  [[ $oom =~ ^-?[0-9]+$ ]] || oom=100
  case "${1:-balanced}" in
    minimal) printf '%s\n' "65536 1024 ${oom}" ;;
    performance) printf '%s\n' "524288 8192 ${oom}" ;;
    *) printf '%s\n' "262144 4096 ${oom}" ;;
  esac
}

# The unit's effective value for a systemd resource property, as systemd resolves
# it. "infinity" and any unreadable value are passed through so the caller can
# avoid lowering them.
proxy_current_limit() {
  local unit="$1" property="$2" value
  platform_has_systemd || return 1
  value="$(systemctl show -p "$property" --value "$unit" 2>/dev/null)" || return 1
  [[ -n $value ]] || return 1
  printf '%s\n' "$value"
}

# Never lower a limit the operator (or the distribution default) already set
# higher. The ephemeral-port rule already follows "widen only"
# (network_ports_need_widening); the drop-in hardcoded three profile values and
# would have quietly cut a host tuned to LimitNOFILE=1048576 down to 262144.
#
# Applies to every ceiling we write, not just LimitNOFILE: TasksMax came from the
# same three hardcoded profiles and would likewise cut a unit that systemd had
# given 4915 (15% of the default pid_max) down to 1024.
proxy_choose_ceiling() {
  local want="${1:-}" current="${2:-}"
  if [[ ! $want =~ ^[0-9]+$ ]]; then printf '%s\n' "$want"; return 0; fi
  case "$current" in
    '')       printf '%s\n' "$want" ;;
    infinity) printf '%s\n' 'infinity' ;;
    *)
      if [[ $current =~ ^[0-9]+$ ]] && (( current > want )); then
        printf '%s\n' "$current"
      else
        printf '%s\n' "$want"
      fi ;;
  esac
}

# systemd 从 <unit 全名>.d 读取 drop-in —— 类型后缀要保留：
# xray.service 的 drop-in 目录是 xray.service.d，不是 xray.d。
#
# 在真实 systemd 257（Debian 13）上实测判定：
#   把同样内容放进 xray.d/          → systemctl show 完全看不到
#   放进 xray.service.d/            → 生效
# 发行版自带的样例也一律是这种形式：systemd-logind.service.d、
# systemd-udevd.service.d、rc-local.service.d。
#
# v1.6.3 曾把这里"修"成 ${1%.service}.d（即 xray.d），反而把一个本来正确的
# 路径改错了，资源限制再次静默失效。证据见 docs/_local/verification/dropin-probe.out.txt。
proxy_dropin_path() {
  printf '%s/%s.d/50-infra-node.conf\n' "${PROXY_SYSTEMD_DIR%/}" "$1"
}

proxy_write_dropin() {
  local unit="$1" restart="${2:-no}" nofile tasks oom path
  if ! core_safe_unit "$unit"; then core_die "非法 systemd unit：$unit"; return 1; fi
  read -r nofile tasks oom < <(proxy_limits_for_profile "${ASSESS_PROFILE:-balanced}")
  nofile="$(proxy_choose_ceiling "$nofile" "$(proxy_current_limit "$unit" LimitNOFILE || true)")"
  tasks="$(proxy_choose_ceiling "$tasks" "$(proxy_current_limit "$unit" TasksMax || true)")"
  path="$(proxy_dropin_path "$unit")"
  txn_begin 'proxy resource limits'
  txn_write_file "$path" 0644 <<EOF_DROPIN || return 1
# Managed by Infra-node. This file only adjusts process resource limits.
[Service]
LimitNOFILE=$nofile
TasksMax=$tasks
OOMScoreAdjust=$oom
EOF_DROPIN
  if core_is_dry_run; then
    core_dry_run_note "would reload systemd and leave $unit running"
    return 0
  fi
  if platform_has_systemd; then
    systemctl daemon-reload
    if [[ $restart == yes ]]; then systemctl restart "$unit"; else ui_info "已写入 $unit 资源限制；未重启服务。"; fi
  fi
}

proxy_apply() {
  local units_csv="${1:-auto}" restart="${2:-no}" unit found=0
  local -a parsed_units=()
  if [[ $restart != yes && $restart != no ]]; then core_die 'restart 参数必须为 yes/no'; return 1; fi
  if [[ $units_csv == auto ]]; then
    while IFS= read -r unit; do [[ -n $unit ]] || continue; found=1; core_run_step "适配 $unit" proxy_write_dropin "$unit" "$restart"; done < <(proxy_discover_units)
  else
    IFS=',' read -r -a parsed_units <<<"$units_csv"
    for unit in "${parsed_units[@]}"; do
      unit="${unit//[[:space:]]/}"; [[ -n $unit ]] || continue
      if ! proxy_unit_exists "$unit"; then core_die "未找到 unit：$unit"; return 1; fi
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
