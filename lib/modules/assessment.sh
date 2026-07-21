#!/usr/bin/env bash

ASSESS_MEM_MB=0
ASSESS_CPU_COUNT=1
ASSESS_DISK_FREE_MB=0
ASSESS_PROFILE=balanced

assessment_profile_valid() { [[ ${1:-} == minimal || ${1:-} == balanced || ${1:-} == performance ]]; }

assessment_collect() {
  ASSESS_MEM_MB="$(platform_mem_mb)"
  ASSESS_CPU_COUNT="$(platform_cpu_count)"
  ASSESS_DISK_FREE_MB="$(platform_disk_free_mb)"
  [[ $ASSESS_MEM_MB =~ ^[0-9]+$ ]] || ASSESS_MEM_MB=0
  [[ $ASSESS_CPU_COUNT =~ ^[0-9]+$ ]] || ASSESS_CPU_COUNT=1
  [[ $ASSESS_DISK_FREE_MB =~ ^[0-9]+$ ]] || ASSESS_DISK_FREE_MB=0
}

assessment_choose_profile() {
  local requested="${1:-auto}"
  assessment_collect
  if assessment_profile_valid "$requested"; then
    ASSESS_PROFILE="$requested"
  elif [[ $requested == auto ]]; then
    if (( ASSESS_MEM_MB < 768 || ASSESS_CPU_COUNT < 2 )); then
      ASSESS_PROFILE=minimal
    elif (( ASSESS_MEM_MB >= 4096 && ASSESS_CPU_COUNT >= 4 )); then
      ASSESS_PROFILE=performance
    else
      ASSESS_PROFILE=balanced
    fi
  else
    core_die "未知配置档位：$requested"
    return 1
  fi
  printf '%s\n' "$ASSESS_PROFILE"
}

assessment_show() {
  local requested="${1:-auto}"
  assessment_choose_profile "$requested" >/dev/null
  ui_section '主机评估'
  ui_kv '系统' "$OS_PRETTY_NAME"
  ui_kv '架构' "$OS_ARCH"
  ui_kv '虚拟化' "$OS_VIRT"
  ui_kv 'CPU' "${ASSESS_CPU_COUNT} vCPU"
  ui_kv '内存' "${ASSESS_MEM_MB} MiB"
  ui_kv '根盘可用' "${ASSESS_DISK_FREE_MB} MiB"
  ui_kv '建议档位' "$ASSESS_PROFILE"
}
