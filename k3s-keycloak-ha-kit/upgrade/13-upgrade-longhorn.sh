#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ $# -ge 2 ]] || fail "Usage: $0 <LONGHORN_TARGET_X.Y.Z> --plan|--apply --backup-evidence <fichier>"
TARGET="${1#v}"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
EVIDENCE="${4:-}"; [[ "${3:-}" == --backup-evidence && -n "$EVIDENCE" ]] || fail '--backup-evidence obligatoire.'
verify_backup_evidence "$EVIDENCE" yes yes yes
CURRENT="$(chart_version longhorn longhorn-system)"; [[ -n "$CURRENT" ]] || fail 'Release Helm Longhorn non trouvée.'
require_longhorn_path "$CURRENT" "$TARGET"
full_preflight
k -n longhorn-system get volumes.longhorn.io -o json > "$REPORT_DIR/longhorn-upgrade-volumes.json"
python3 - "$REPORT_DIR/longhorn-upgrade-volumes.json" <<'PYV2'
import json,sys
items=json.load(open(sys.argv[1])).get('items',[])
v2=[v['metadata']['name'] for v in items if v.get('spec',{}).get('dataEngine')=='v2']
if v2: raise SystemExit('Volumes Longhorn V2 détectés : '+', '.join(v2)+'. La procédure de pré-mise à niveau V2 doit être exécutée manuellement selon la documentation de la version cible; upgrade automatique bloqué.')
PYV2
helm repo add longhorn https://charts.longhorn.io --force-update >/dev/null
helm repo update longhorn >/dev/null
helm show chart longhorn/longhorn --version "$TARGET" >/dev/null || fail "Chart Longhorn $TARGET introuvable."
printf 'Longhorn: %s -> %s\nCommande prévue: helm upgrade longhorn longhorn/longhorn -n longhorn-system --version %s --reuse-values --wait --timeout 40m\n' "$CURRENT" "$TARGET" "$TARGET"
if [[ "$APPLY" == --plan ]]; then echo 'PLAN SEUL : aucune modification.'; exit 0; fi
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$(date +%Y%m%d-%H%M%S).bak"
# Pas de --atomic ni de rollback automatique : Longhorn ne supporte pas le downgrade.
helm upgrade longhorn longhorn/longhorn --namespace longhorn-system --version "$TARGET" --reuse-values --wait --timeout 40m
k -n longhorn-system rollout status daemonset/longhorn-manager --timeout=1200s
k -n longhorn-system rollout status daemonset/longhorn-csi-plugin --timeout=1200s
assert_longhorn_healthy
set_config_var LONGHORN_VERSION "$TARGET"
full_preflight
printf '\nLonghorn mis à niveau vers %s. Ne pas tenter de downgrade.\n' "$TARGET"
