#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -x $ROOT/bin/infra-node ]]; then exec "$ROOT/bin/infra-node" "$@"; fi
exec /usr/local/bin/infra-node "$@"
