#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ "$HEADLAMP_INSTALL" == true ]] || fail 'HEADLAMP_INSTALL=false: Headlamp optionnel n’est pas géré par ce kit.'
[[ $# -ge 2 ]] || fail "Usage: $0 <HEADLAMP_CHART_X.Y.Z> --plan|--apply"
TARGET="$1"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
CURRENT="$(chart_version "$HEADLAMP_RELEASE" "$HEADLAMP_NAMESPACE")"; [[ -n "$CURRENT" ]] || fail 'Release Headlamp absente.'
require_newer_version "$CURRENT" "$TARGET"
full_preflight
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update >/dev/null; helm repo update headlamp >/dev/null
helm show chart headlamp/headlamp --version "$TARGET" >/dev/null || fail "Chart Headlamp $TARGET absent."
printf 'Headlamp chart: %s -> %s\n' "$CURRENT" "$TARGET"
if [[ "$APPLY" == --plan ]]; then echo 'PLAN SEUL : aucune modification.'; exit 0; fi
helm upgrade "$HEADLAMP_RELEASE" headlamp/headlamp -n "$HEADLAMP_NAMESPACE" --version "$TARGET" --reuse-values --wait --timeout 10m
k -n "$HEADLAMP_NAMESPACE" rollout status "deployment/$HEADLAMP_RELEASE" --timeout=600s
set_config_var HEADLAMP_CHART_VERSION "$TARGET"
full_preflight
