#!/usr/bin/env bash
# Met d'abord à niveau les pods Keycloak via le CR, puis l'Operator/CRD vers le même tag.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ $# -ge 3 ]] || fail "Usage: $0 <KEYCLOAK_TARGET_X.Y.Z> --plan|--apply --backup-evidence <fichier>"
TARGET="$1"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
EVIDENCE="${4:-}"; [[ "${3:-}" == --backup-evidence && -n "$EVIDENCE" ]] || fail '--backup-evidence obligatoire.'
verify_backup_evidence "$EVIDENCE" yes yes yes
CURRENT="$KEYCLOAK_VERSION"
require_newer_version "$CURRENT" "$TARGET"
full_preflight
REF="https://github.com/keycloak/keycloak-k8s-resources/kubernetes?ref=${TARGET}"
printf 'Keycloak/Operator: %s -> %s. Ordre prévu: CR image -> pods Ready -> Operator/CRD.\n' "$CURRENT" "$TARGET"
if [[ "$APPLY" == --plan ]]; then
  printf 'Commande image: kubectl patch keycloak %s -n %s --type=merge -p ...\n' "$KEYCLOAK_NAME" "$KEYCLOAK_NAMESPACE"
  printf 'Commande Operator: kubectl apply -k %s\n' "$REF"
  echo 'PLAN SEUL : aucune modification.'; exit 0
fi
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$(date +%Y%m%d-%H%M%S).bak"
# Mise à jour du serveur gérée via la CR. Ne pas utiliser kubectl set image sur des pods gérés par l'Operator.
k -n "$KEYCLOAK_NAMESPACE" patch keycloak "$KEYCLOAK_NAME" --type=merge -p "{\"spec\":{\"image\":\"quay.io/keycloak/keycloak:$TARGET\"}}"
DEADLINE=$((SECONDS+2400)); PODS_JSON="$REPORT_DIR/keycloak-upgrade-pods.json"
while (( SECONDS < DEADLINE )); do
  if k -n "$KEYCLOAK_NAMESPACE" get pods -l app.kubernetes.io/component=server -o json > "$PODS_JSON" 2>/dev/null; then
    if python3 - "$PODS_JSON" "$KEYCLOAK_REPLICAS" "$TARGET" <<'PYREADY'
import json,sys
ps=json.load(open(sys.argv[1])).get('items',[]); want=int(sys.argv[2]); image=sys.argv[3]
r=[p for p in ps if p.get('status',{}).get('phase')=='Running' and p.get('status',{}).get('containerStatuses') and all(c.get('ready') for c in p['status']['containerStatuses']) and all(c.get('image','').endswith(':'+image) for c in p['status']['containerStatuses'])]
raise SystemExit(0 if len(r)==want else 1)
PYREADY
    then break; fi
  fi
  sleep 10
done
python3 - "$PODS_JSON" "$KEYCLOAK_REPLICAS" "$TARGET" <<'PYREADY'
import json,sys
ps=json.load(open(sys.argv[1])).get('items',[]); want=int(sys.argv[2]); image=sys.argv[3]
r=[p for p in ps if p.get('status',{}).get('phase')=='Running' and p.get('status',{}).get('containerStatuses') and all(c.get('ready') for c in p['status']['containerStatuses']) and all(c.get('image','').endswith(':'+image) for c in p['status']['containerStatuses'])]
if len(r)!=want: raise SystemExit(f'Keycloak {len(r)}/{want} pods Ready sur image {image}; Operator non modifié. Diagnostiquer avant toute suite.')
PYREADY
# La doc officielle recommande généralement de mettre d'abord les CRs/images à niveau, puis l'Operator;
# vérifier les notes de version pour les exceptions majeures avant d'appliquer.
k apply -k "$REF"
k -n "$KEYCLOAK_NAMESPACE" rollout status deployment/keycloak-operator --timeout=900s
READY="$(k -n "$KEYCLOAK_NAMESPACE" get keycloak "$KEYCLOAK_NAME" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
[[ "$READY" == True ]] || fail 'Keycloak CR non Ready après mise à jour Operator. Ne pas poursuivre.'
set_config_var KEYCLOAK_VERSION "$TARGET"
set_config_var KEYCLOAK_OPERATOR_REF "$TARGET"
full_preflight
"$ROOT_DIR/scripts/10-check.sh"
"$ROOT_DIR/scripts/11-check-ha.sh"
printf '\nKeycloak et Operator mis à niveau vers %s. Aucun downgrade automatique n’est tenté.\n' "$TARGET"
