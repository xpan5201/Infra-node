#!/usr/bin/env bash
# Helper for tests/smoke.sh: drives update_install_from_source in its OWN process
# so that errexit is genuinely active. A `( ... ) || rc=$?` wrapper suppresses
# errexit for the whole subshell (bash errexit rules), which makes the preflight
# gate look broken even when it works. Verified on real Debian 13 via WSL.
#
# usage: git-gate.sh <repo-root> <source-tree> <install-root>
#
# Sets the module-level INFRA_* globals the sourced libraries read, and loads them
# through a computed path; neither is followable by a static analyser.
# shellcheck disable=SC2034,SC1090,SC1091
set -Eeuo pipefail
ROOT="$1"
TREE="$2"
TARGET="$3"

export INFRA_TEST_MODE=1
# The defaults file uses hard assignments (so it cannot be overridden from the
# environment), hence these must be supplied AFTER sourcing it.
source "$ROOT/config/defaults.env"
INFRA_ROOT="$ROOT"
INFRA_VERSION="$(cat "$ROOT/VERSION")"
INFRA_INSTALL_DIR="$TARGET/opt/infra-node"
INFRA_COMMAND_DIR="$TARGET/bin"
INFRA_ETC_DIR="$TARGET/etc"
INFRA_STATE_DIR="$TARGET/state"
INFRA_LOG_DIR="$TARGET/log"
INFRA_BACKUP_DIR="$TARGET/backup"

for lib in ui core platform packages transaction updater; do source "$ROOT/lib/$lib.sh"; done
ui_detect
core_init git-gate

# Force the preflight to fail, independent of the platform skip-guards.
update_run_smoke() { return 1; }

update_install_from_source "$TREE" https://github.com/xpan5201/Infra-node.git main
