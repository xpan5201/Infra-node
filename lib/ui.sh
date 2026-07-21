#!/usr/bin/env bash

ui_detect() {
  if [[ ! -t 1 || ${TERM:-dumb} == dumb || ${INFRA_NO_COLOR:-0} -eq 1 ]]; then
    UI_RED='' UI_GREEN='' UI_YELLOW='' UI_BLUE='' UI_BOLD='' UI_RESET=''
  else
    UI_RED=$'\033[31m'; UI_GREEN=$'\033[32m'; UI_YELLOW=$'\033[33m'
    UI_BLUE=$'\033[36m'; UI_BOLD=$'\033[1m'; UI_RESET=$'\033[0m'
  fi
}

ui_banner() {
  printf '%s\n' "${UI_BOLD:-}Infra-node v${INFRA_VERSION:-unknown}${UI_RESET:-}"
  printf '%s\n' 'Secure · Fast · Light · On demand'
}
ui_section() { printf '\n%s%s%s\n' "${UI_BOLD:-}" "$*" "${UI_RESET:-}"; printf '%s\n' '────────────────────────────────────────────────────────────'; }
ui_ok()    { printf '%s✓%s %s\n' "${UI_GREEN:-}" "${UI_RESET:-}" "$*"; }
ui_info()  { printf '%s◆%s %s\n' "${UI_BLUE:-}" "${UI_RESET:-}" "$*"; }
ui_warn()  { printf '%s!%s %s\n' "${UI_YELLOW:-}" "${UI_RESET:-}" "$*" >&2; }
ui_error() { printf '%s×%s %s\n' "${UI_RED:-}" "${UI_RESET:-}" "$*" >&2; }
ui_kv()    { printf '  %-18s %s\n' "$1" "$2"; }

ui_confirm() {
  local prompt="$1" default="${2:-no}" reply
  if [[ ${INFRA_ASSUME_YES:-0} -eq 1 ]]; then return 0; fi
  if [[ ${INFRA_NON_INTERACTIVE:-0} -eq 1 || ! -t 0 ]]; then [[ $default == yes ]]; return; fi
  if [[ $default == yes ]]; then
    read -r -p "$prompt [Y/n] " reply || return 1
    [[ -z $reply || $reply =~ ^[Yy]$ ]]
  else
    read -r -p "$prompt [y/N] " reply || return 1
    [[ $reply =~ ^[Yy]$ ]]
  fi
}
