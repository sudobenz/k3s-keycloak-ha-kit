#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ $# -ge 2 ]] || fail "Usage: $0 <CERT_MANAGER_TARGET_vX.Y.Z> --plan|--apply --backup-evidence <fichier>"
TARGET="$1"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
EVIDENCE="${4:-}"; [[ "${3:-}" == --backup-evidence && -n "$EVIDENCE" ]] || fail '--backup-evidence obligatoire.'
verify_backup_evidence "$EVIDENCE" yes yes no
TARGET_NO_V="${TARGET#v}"
CURRENT_RELEASE="$(chart_version cert-manager "$CERT_MANAGER_NAMESPACE")"
[[ -n "$CURRENT_RELEASE" ]] || fail "Release Helm cert-manager absente dans $CERT_MANAGER_NAMESPACE. Si elle est gérée par un autre outil, ne pas la modifier ici."
CURRENT_NO_V="${CURRENT_RELEASE#v}"
require_same_minor "$CURRENT_NO_V" "$TARGET_NO_V"
full_preflight
helm show chart oci://quay.io/jetstack/charts/cert-manager --version "$TARGET" >/dev/null || fail "Chart cert-manager $TARGET introuvable."
printf 'cert-manager: %s -> %s. CRD incluses dans la release Helm (crds.enabled=true).\n' "$CURRENT_RELEASE" "$TARGET"
if [[ "$APPLY" == --plan ]]; then echo "Commande prévue: helm upgrade cert-manager oci://quay.io/jetstack/charts/cert-manager -n $CERT_MANAGER_NAMESPACE --version $TARGET --reuse-values --set crds.enabled=true --wait"; echo 'PLAN SEUL : aucune modification.'; exit 0; fi
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$(date +%Y%m%d-%H%M%S).bak"
helm upgrade cert-manager oci://quay.io/jetstack/charts/cert-manager --namespace "$CERT_MANAGER_NAMESPACE" --version "$TARGET" --reuse-values --set crds.enabled=true --wait --timeout 15m
for d in cert-manager cert-manager-cainjector cert-manager-webhook; do k -n "$CERT_MANAGER_NAMESPACE" rollout status "deployment/$d" --timeout=600s; done
set_config_var CERT_MANAGER_VERSION "$TARGET"
full_preflight
printf '\ncert-manager mis à niveau vers %s. Vérifier Issuers, ClusterIssuers et certificats Ready.\n' "$TARGET"
