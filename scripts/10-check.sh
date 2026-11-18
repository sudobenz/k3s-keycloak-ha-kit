#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; validate_common; require_cluster
WARNINGS=0
check_deployment() {
  local ns="$1" name="$2" ready desired
  if k get deployment "$name" -n "$ns" >/dev/null 2>&1; then
    ready="$(k get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    desired="$(k get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    printf 'Deployment %-34s ready=%s/%s\n' "$ns/$name" "${ready:-0}" "${desired:-1}"
    [[ "${ready:-0}" == "${desired:-1}" ]] || WARNINGS=$((WARNINGS+1))
  else printf 'MANQUANT Deployment %s/%s\n' "$ns" "$name"; WARNINGS=$((WARNINGS+1)); fi
}
printf '=== K3s nodes ===\n'; k get nodes -o wide
printf '\n=== VIP / Traefik ===\n'; k -n kube-system get pods -o wide | grep -E 'kube-vip|traefik' || true; k -n kube-system get svc traefik -o wide || WARNINGS=$((WARNINGS+1))
TRAEFIK_POLICY="$(k -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}' 2>/dev/null || true)"
if [[ "$TRAEFIK_POLICY" != "Local" ]]; then
  warn "Traefik externalTrafficPolicy doit être Local pour préserver l'IP cliente (valeur : ${TRAEFIK_POLICY:-absente})."
  WARNINGS=$((WARNINGS+1))
else
  printf 'Traefik externalTrafficPolicy=Local : OK (préservation de l’IP source).\n'
fi
printf '\n=== Longhorn ===\n'; k -n longhorn-system get pods -o wide || WARNINGS=$((WARNINGS+1)); k get storageclass "$PG_STORAGE_CLASS" >/dev/null || WARNINGS=$((WARNINGS+1))
printf '\n=== CloudNativePG ===\n'; check_deployment "$CNPG_NAMESPACE" cnpg-controller-manager; k get cluster "$CNPG_CLUSTER_NAME" -n "$KEYCLOAK_NAMESPACE" -o wide || WARNINGS=$((WARNINGS+1))
k wait --for=condition=Ready "cluster/${CNPG_CLUSTER_NAME}" -n "$KEYCLOAK_NAMESPACE" --timeout=30s >/dev/null 2>&1 || { warn 'Cluster PostgreSQL CNPG non Ready.'; WARNINGS=$((WARNINGS+1)); }
printf '\n=== cert-manager ===\n'; for d in cert-manager cert-manager-cainjector cert-manager-webhook; do check_deployment "$CERT_MANAGER_NAMESPACE" "$d"; done
printf '\n=== Keycloak Operator + server ===\n'; check_deployment "$KEYCLOAK_NAMESPACE" keycloak-operator
k get keycloak "$KEYCLOAK_NAME" -n "$KEYCLOAK_NAMESPACE" -o wide || WARNINGS=$((WARNINGS+1))
k get pods -n "$KEYCLOAK_NAMESPACE" -o wide
k get svc,ingress -n "$KEYCLOAK_NAMESPACE" -o wide
printf '\n=== TLS Secret metadata (aucune clé privée affichée) ===\n'
k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" -o custom-columns='NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp' || WARNINGS=$((WARNINGS+1))
if command -v curl >/dev/null 2>&1; then
  printf '\n=== OIDC discovery via VIP ===\n'
  CODE="$(curl --silent --show-error --insecure --connect-timeout 5 --max-time 20 --resolve "${KEYCLOAK_FQDN}:443:${INGRESS_VIP}" -o "$ROOT_DIR/output/oidc-discovery.json" -w '%{http_code}' "https://${KEYCLOAK_FQDN}/realms/master/.well-known/openid-configuration" 2>/dev/null || true)"
  printf 'HTTP %s\n' "${CODE:-échec}"
  [[ "$CODE" == 200 ]] && grep -q '"issuer"' "$ROOT_DIR/output/oidc-discovery.json" || { warn 'Discovery OIDC non validée. Contrôler DNS/VIP/Ingress/TLS/Readiness.'; WARNINGS=$((WARNINGS+1)); }
fi
printf '\n=== Synthèse ===\n'
if (( WARNINGS > 0 )); then printf '%s contrôle(s) en anomalie.\n' "$WARNINGS"; exit 1; fi
printf 'Contrôles de base réussis. Cela ne remplace pas un test de bascule et de restauration.\n'
