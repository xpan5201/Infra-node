#!/usr/bin/env bash
# Sets module-level globals consumed by the sourced libraries via a computed
# path; see tests/smoke.sh for the same rationale.
# shellcheck disable=SC2034,SC1090,SC1091
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/infra-node-integration.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

# Make a failure self-describing. Without this, a failing step inside the install
# preflight only surfaces as "Smoke Test 未通过" with no line number, which cost
# several CI round trips to localise.
trap 'printf "\nINTEGRATION FAILED at %s line %s: %s (rc=%s)\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR

cp -a -- "$ROOT" "$TMP/source"
rm -rf -- "$TMP/source/.git" "$TMP/source/dist"
cd "$TMP/source"

# `cp -a` preserves the *source* directory's ownership. When a privileged runner
# (GitHub Actions runs this container as root) copies a checkout owned by another
# user, the fixture directory ends up owned by that other user while git runs as
# root. Git then refuses every repository operation with
#   fatal: detected dubious ownership in repository at '...'
# and exits 128. `git init` is unaffected (it only creates files), so the failure
# surfaced at the next command and looked unrelated. Declaring the fixture safe is
# what Git itself recommends, and it also covers an externally set GIT_CONFIG_GLOBAL.
if [[ $(id -u) -eq 0 ]]; then
  git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$PWD" \
    || git config --global --add safe.directory "$PWD" || true
fi

git init -q -b main
git config user.email test@example.invalid
git config user.name InfraTest
git remote add origin https://github.com/xpan5201/Infra-node.git

# Reproduce the reported mode-loss path: a clean Git tree whose known entrypoints
# are stored as 100644, then staged through git archive by the bootstrap updater.
chmod 0644 bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh
git add .
git commit -qm 'integration fixture: web-upload file modes'
for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do
  [[ $(git ls-files -s "$path" | awk '{print $1}') == 100644 ]] || { echo "fixture mode mismatch: $path" >&2; exit 1; }
done

# shellcheck disable=SC1091
source "$TMP/source/config/defaults.env"
export INFRA_TEST_MODE=1
INFRA_ROOT="$TMP/source"
INFRA_VERSION="$(cat "$TMP/source/VERSION")"
INFRA_INSTALL_DIR="$TMP/opt/infra-node"
INFRA_COMMAND_DIR="$TMP/usr/local/bin"
INFRA_ETC_DIR="$TMP/etc/infra-node"
INFRA_STATE_DIR="$TMP/var/lib/infra-node"
INFRA_LOG_DIR="$TMP/var/log/infra-node"
INFRA_BACKUP_DIR="$TMP/var/backups/infra-node"
for lib in ui core platform packages transaction updater; do source "$TMP/source/lib/$lib.sh"; done
ui_detect
core_init integration-install

update_install_from_source "$TMP/source" https://github.com/xpan5201/Infra-node.git main >/dev/null

if [[ ${INFRA_SMOKE_SKIP_SYMLINKS:-0} -eq 1 ]]; then
  # Git-Bash cannot create symlinks without elevation, so the link assertions are
  # skipped rather than failing on an emulated regular file. CI never sets this.
  printf 'SKIP command-link assertions (INFRA_SMOKE_SKIP_SYMLINKS=1)\n'
else
  [[ -L $INFRA_COMMAND_DIR/infra-node && -L $INFRA_COMMAND_DIR/pvf ]] || { echo 'command links missing' >&2; exit 1; }
fi
for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do
  [[ -x $INFRA_INSTALL_DIR/$path ]] || { echo "entrypoint not normalized: $path" >&2; exit 1; }
done
[[ ! -e $INFRA_INSTALL_DIR/CHECKSUMS.sha256 ]] || { echo 'legacy checksum manifest installed' >&2; exit 1; }
for required in VERSION bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh config/defaults.env; do
  [[ -f $INFRA_INSTALL_DIR/$required ]] || { echo "required file missing: $required" >&2; exit 1; }
done
if [[ ${INFRA_SMOKE_SKIP_SYMLINKS:-0} -eq 1 ]]; then
  # Windows cannot exec an extensionless script through a symlink, so exercise the
  # installed binary directly instead of via the command link.
  "$INFRA_INSTALL_DIR/bin/infra-node" version | grep -Fq "$INFRA_VERSION"
else
  "$INFRA_COMMAND_DIR/infra-node" version | grep -Fq "$INFRA_VERSION"
fi

# Reinstalling the same Git commit must refresh the tree instead of trusting stale
# local files now that the static checksum gate has been removed.
if [[ ${INFRA_SMOKE_SKIP_SYMLINKS:-0} -eq 1 ]]; then
  # The reinstall refuses to touch an install whose command link is not a symlink,
  # and Windows cannot create one, so this scenario needs a POSIX filesystem.
  printf 'SKIP same-commit reinstall assertion (INFRA_SMOKE_SKIP_SYMLINKS=1)\n'
else
  printf 'locally modified\n' >"$INFRA_INSTALL_DIR/README.md"
  core_release_lock
  update_install_from_source "$TMP/source" https://github.com/xpan5201/Infra-node.git main >/dev/null
  cmp -s "$TMP/source/README.md" "$INFRA_INSTALL_DIR/README.md" || { echo 'same-commit reinstall did not refresh modified tree' >&2; exit 1; }
fi

printf 'Integration install passed.\n'
