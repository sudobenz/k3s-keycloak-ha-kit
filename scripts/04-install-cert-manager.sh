#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; validate_common; require_cluster; require_cmd helm
if helm status cert-manager -n "$CERT_MANAGER_NAMESPACE" >/dev/null 2>&1; then
  fail "Release cert-manager déjà présente : ce script est réservé à l'installation initiale. Utilisez upgrade/15-upgrade-cert-manager.sh."
fi
info "Installation cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  --namespace "$CERT_MANAGER_NAMESPACE" --create-namespace \
  --set crds.enabled=true --wait --timeout=10m
for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
  k rollout status "deployment/${deployment}" -n "$CERT_MANAGER_NAMESPACE" --timeout=600s
done
for crd in certificates.cert-manager.io certificaterequests.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io orders.acme.cert-manager.io challenges.acme.cert-manager.io; do k get crd "$crd" >/dev/null; done
k -n "$CERT_MANAGER_NAMESPACE" get pods -o wide
