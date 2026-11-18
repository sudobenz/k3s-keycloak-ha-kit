#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; validate_common; require_cluster; export_proxy_environment
if k get deployment cnpg-controller-manager -n "$CNPG_NAMESPACE" >/dev/null 2>&1; then
  fail "CloudNativePG Operator déjà présent : ce script est réservé à l'installation initiale. Utilisez upgrade/11-upgrade-cnpg-operator.sh."
fi
MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
info "Installation CloudNativePG ${CNPG_VERSION}"
k create namespace "$CNPG_NAMESPACE" --dry-run=client -o yaml | k apply -f -
curl -fsSL "$MANIFEST_URL" -o "$TMP" || fail "Téléchargement impossible : $MANIFEST_URL"
k apply --server-side -f "$TMP"
for attempt in $(seq 1 60); do
  if k get deployment cnpg-controller-manager -n "$CNPG_NAMESPACE" >/dev/null 2>&1; then break; fi
  sleep 5
done
k rollout status deployment/cnpg-controller-manager -n "$CNPG_NAMESPACE" --timeout=600s
k get crd clusters.postgresql.cnpg.io >/dev/null
k -n "$CNPG_NAMESPACE" get pods -o wide
