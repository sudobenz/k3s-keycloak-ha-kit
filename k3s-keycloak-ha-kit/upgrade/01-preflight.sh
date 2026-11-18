#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config
full_preflight
"$ROOT_DIR/scripts/10-check.sh"
"$ROOT_DIR/scripts/11-check-ha.sh"
printf '\nPré-contrôle terminé. Aucune ressource n’a été modifiée.\n'
