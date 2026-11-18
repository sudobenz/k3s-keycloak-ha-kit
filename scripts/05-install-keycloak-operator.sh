#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; validate_common; require_cluster; export_proxy_environment
info "Installation de l’Operator officiel Keycloak ${KEYCLOAK_OPERATOR_REF} dans ${KEYCLOAK_NAMESPACE}"
k create namespace "$KEYCLOAK_NAMESPACE" --dry-run=client -o yaml | k apply -f -
if k get deployment keycloak-operator -n "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1; then
  warn 'Operator déjà présent ; aucune réinstallation distante effectuée.'
else
  k apply -k "https://github.com/keycloak/keycloak-k8s-resources/kubernetes?ref=${KEYCLOAK_OPERATOR_REF}"
fi
k rollout status deployment/keycloak-operator -n "$KEYCLOAK_NAMESPACE" --timeout=600s
k get crd keycloaks.k8s.keycloak.org >/dev/null
k -n "$KEYCLOAK_NAMESPACE" get pods -o wide
printf '\nOperator installé en un seul replica de contrôle. Les instances Keycloak HA sont configurées séparément.\n'
