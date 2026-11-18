#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; validate_common; require_cluster
WARN=0
check_crd() { if k get crd "$1" >/dev/null 2>&1; then printf 'OK       CRD %s\n' "$1"; else printf 'MANQUANT CRD %s\n' "$1"; WARN=$((WARN+1)); fi; }
check_deploy() { local ns="$1" name="$2" r d; if k get deploy "$name" -n "$ns" >/dev/null 2>&1; then r="$(k get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"; d="$(k get deploy "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"; printf 'OK       Deployment %s/%s %s/%s Ready\n' "$ns" "$name" "${r:-0}" "${d:-1}"; [[ "${r:-0}" == "${d:-1}" ]] || WARN=$((WARN+1)); else printf 'MANQUANT Deployment %s/%s\n' "$ns" "$name"; WARN=$((WARN+1)); fi; }
printf '=== Nœuds ===\n'; k get nodes -o wide
printf '\n=== VIPs / Traefik ===\n'; k -n kube-system get svc traefik -o wide; k -n kube-system get pods -o wide | grep -E 'traefik|kube-vip' || true
printf '\n=== Longhorn ===\n'; k -n longhorn-system get pods -o wide; k get storageclass longhorn-pg-local longhorn-rwo-3replicas
printf '\n=== CloudNativePG ===\n'; check_deploy "$CNPG_NAMESPACE" cnpg-controller-manager; check_crd clusters.postgresql.cnpg.io
printf '\n=== cert-manager ===\n'; for d in cert-manager cert-manager-cainjector cert-manager-webhook; do check_deploy "$CERT_MANAGER_NAMESPACE" "$d"; done
for c in certificates.cert-manager.io certificaterequests.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io orders.acme.cert-manager.io challenges.acme.cert-manager.io; do check_crd "$c"; done
printf '\n=== Keycloak Operator / CR ===\n'; check_deploy "$KEYCLOAK_NAMESPACE" keycloak-operator; check_crd keycloaks.k8s.keycloak.org
k get keycloak "$KEYCLOAK_NAME" -n "$KEYCLOAK_NAMESPACE" -o wide
if [[ "$HEADLAMP_INSTALL" == true ]]; then check_deploy "$HEADLAMP_NAMESPACE" "$HEADLAMP_RELEASE"; fi
if (( WARN > 0 )); then printf '\n%s anomalie(s) détectée(s).\n' "$WARN"; exit 1; fi
printf '\nContrôles plateforme réussis.\n'
