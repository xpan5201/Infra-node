#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BOOTSTRAP_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) BOOTSTRAP_YES=1 ;;
    --no-color) export INFRA_NO_COLOR=1 ;;
    *) printf '未知安装参数：%s\n' "$arg" >&2; exit 2 ;;
  esac
done

bootstrap_require_root() {
  if [[ $(id -u) -ne 0 ]]; then printf '请使用 sudo bash bootstrap.sh\n' >&2; exit 1; fi
}

bootstrap_dependencies() {
  local missing=() cmd package
  while read -r cmd package; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$package"); done <<'EOF_DEPS'
git git
curl curl
sha256sum coreutils
find findutils
flock util-linux
setpriv util-linux
timeout coreutils
tar tar
EOF_DEPS
  ((${#missing[@]}==0)) && return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates "${missing[@]}"
}

bootstrap_require_root
bootstrap_dependencies
# shellcheck disable=SC1091
source "$BOOTSTRAP_ROOT/config/defaults.env"
((BOOTSTRAP_YES==0)) || INFRA_ASSUME_YES=1
INFRA_ROOT="$BOOTSTRAP_ROOT"
INFRA_VERSION="$(tr -d '\r\n' <"$BOOTSTRAP_ROOT/VERSION")"
for _lib in ui core platform packages transaction updater; do source "$BOOTSTRAP_ROOT/lib/${_lib}.sh"; done
ui_detect
core_init "$@"
ui_banner
ui_section '仓库校验与原子安装'
update_install_from_source "$BOOTSTRAP_ROOT" "$INFRA_REPO_URL" "$INFRA_REPO_REF"

if ui_confirm '立即部署节点基础设施？' yes; then
  deploy_args=()
  ((INFRA_ASSUME_YES==0)) || deploy_args+=(--yes)
  # 安装器与部署命令共用同一把锁。exec 不会触发 EXIT trap，且打开的
  # flock 文件描述符会被新进程继承，因此必须在交接前显式释放。
  core_release_lock
  exec "$INFRA_INSTALL_DIR/bin/infra-node" "${deploy_args[@]}" deploy
else
  ui_info '安装完成。稍后运行：sudo infra-node deploy'
fi
