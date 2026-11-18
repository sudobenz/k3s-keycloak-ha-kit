#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; validate_common; require_cluster
k get keycloak "$KEYCLOAK_NAME" -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail 'CR Keycloak absente.'
k get svc "${KEYCLOAK_NAME}-service" -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail "Service ${KEYCLOAK_NAME}-service absent."
k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail 'Secret TLS absent : exécuter 07-prepare-tls-secret.sh.'
mkdir -p "$ROOT_DIR/output"
cat > "$ROOT_DIR/output/keycloak-ingress.yaml" <<EOF_INGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${KEYCLOAK_NAME}
  namespace: ${KEYCLOAK_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts:
        - ${KEYCLOAK_FQDN}
      secretName: ${KEYCLOAK_TLS_SECRET}
  rules:
    - host: ${KEYCLOAK_FQDN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${KEYCLOAK_NAME}-service
                port:
                  number: 8080
EOF_INGRESS
k apply -f "$ROOT_DIR/output/keycloak-ingress.yaml"
k get ingress "$KEYCLOAK_NAME" -n "$KEYCLOAK_NAMESPACE" -o wide
