#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/infra-node-integration.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

cp -a -- "$ROOT" "$TMP/source"
rm -rf -- "$TMP/source/.git" "$TMP/source/dist"
cd "$TMP/source"
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

[[ -L $INFRA_COMMAND_DIR/infra-node && -L $INFRA_COMMAND_DIR/pvf ]] || { echo 'command links missing' >&2; exit 1; }
for path in bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh; do
  [[ -x $INFRA_INSTALL_DIR/$path ]] || { echo "entrypoint not normalized: $path" >&2; exit 1; }
done
[[ ! -e $INFRA_INSTALL_DIR/CHECKSUMS.sha256 ]] || { echo 'legacy checksum manifest installed' >&2; exit 1; }
for required in VERSION bin/infra-node bootstrap.sh proxy-vps-foundation.sh tests/smoke.sh config/defaults.env; do
  [[ -f $INFRA_INSTALL_DIR/$required ]] || { echo "required file missing: $required" >&2; exit 1; }
done
"$INFRA_COMMAND_DIR/infra-node" version | grep -Fq "$INFRA_VERSION"

# Reinstalling the same Git commit must refresh the tree instead of trusting stale
# local files now that the static checksum gate has been removed.
printf 'locally modified\n' >"$INFRA_INSTALL_DIR/README.md"
core_release_lock
update_install_from_source "$TMP/source" https://github.com/xpan5201/Infra-node.git main >/dev/null
cmp -s "$TMP/source/README.md" "$INFRA_INSTALL_DIR/README.md" || { echo 'same-commit reinstall did not refresh modified tree' >&2; exit 1; }

printf 'Integration install passed.\n'
