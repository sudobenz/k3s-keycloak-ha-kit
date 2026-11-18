#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
[[ $# -eq 1 ]] || { echo "Usage: $0 <NODE_NAME>" >&2; exit 2; }
exec bash "$ROOT_DIR/upgrade/18-host-maintenance.sh" prepare "$1"
