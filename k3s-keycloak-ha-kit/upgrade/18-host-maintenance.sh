#!/usr/bin/env bash
# Prépare/réintègre un nœud avant/après la maintenance OS déclenchée par PatchMon.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ $# -eq 2 ]] || fail "Usage: $0 prepare|finish <NODE_NAME>"
MODE="$1"; NODE="$2"
case "$NODE" in "$NODE1_NAME"|"$NODE2_NAME"|"$NODE3_NAME") ;; *) fail "Nœud non déclaré dans config.env: $NODE";; esac
[[ "$(hostname -s)" == "$NODE" ]] || fail "Exécuter sur l'hôte ciblé $NODE (hostname actuel: $(hostname -s))."
case "$MODE" in
  prepare)
    prepare_node_for_maintenance "$NODE"
    printf '\nNœud %s prêt pour PatchMon. Exécuter les mises à jour maintenant; ne pas planifier de second hôte. Le redémarrage est permis seulement après fin du gestionnaire de paquets.\n' "$NODE"
    ;;
  finish)
    finish_node_maintenance "$NODE"
    ;;
  *) fail 'Mode attendu: prepare ou finish.';;
esac
