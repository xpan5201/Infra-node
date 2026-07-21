#!/usr/bin/env bash

experience_run() {
  local url="${1:-$INFRA_TEST_URL}" output started elapsed
  if [[ ! $url =~ ^https:// ]]; then core_die '体验测试仅允许 HTTPS URL。'; return 1; fi
  if ! command -v curl >/dev/null 2>&1; then core_die 'curl 不可用。'; return 1; fi
  ui_section '按需网络体验测试'
  started="$(date +%s%3N 2>/dev/null || date +%s000)"
  if ! output="$(curl --fail --silent --show-error --location --max-time 12 --connect-timeout 5 --proto '=https' --tlsv1.2 "$url")"; then core_die 'HTTPS 探测失败。'; return 1; fi
  elapsed=$(( $(date +%s%3N 2>/dev/null || date +%s000) - started ))
  ui_kv '目标' "$url"
  ui_kv '耗时' "${elapsed} ms"
  printf '%s\n' "$output" | sed -n '1,12p'
}
