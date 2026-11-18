#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; validate_common; require_cluster
k get deployment keycloak-operator -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail 'Keycloak Operator absent : exécuter 05-install-keycloak-operator.sh.'
k wait --for=condition=Ready "cluster/${CNPG_CLUSTER_NAME}" -n "$KEYCLOAK_NAMESPACE" --timeout=1800s
k get secret "$KEYCLOAK_DB_SECRET" -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail 'Secret PostgreSQL absent.'
mkdir -p "$ROOT_DIR/output"
MANIFEST="$ROOT_DIR/output/keycloak.yaml"
cat > "$MANIFEST" <<EOF_KEYCLOAK
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: ${KEYCLOAK_NAME}
  namespace: ${KEYCLOAK_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: keycloak
spec:
  instances: ${KEYCLOAK_REPLICAS}
  image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
  db:
    vendor: postgres
    host: ${CNPG_CLUSTER_NAME}-rw.${KEYCLOAK_NAMESPACE}.svc.cluster.local
    port: 5432
    database: ${KEYCLOAK_DB_NAME}
    usernameSecret:
      name: ${KEYCLOAK_DB_SECRET}
      key: username
    passwordSecret:
      name: ${KEYCLOAK_DB_SECRET}
      key: password
    poolMaxSize: ${KEYCLOAK_DB_POOL_MAX}
  http:
    httpEnabled: true
  hostname:
    hostname: https://${KEYCLOAK_FQDN}
    strict: true
  proxy:
    headers: xforwarded
  scheduling:
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: ${KEYCLOAK_NAME}
            app.kubernetes.io/managed-by: keycloak-operator
            app.kubernetes.io/instance: ${KEYCLOAK_NAME}
            app.kubernetes.io/component: server
  ingress:
    enabled: false
  networkPolicy:
    enabled: true
    # Keycloak accepte les en-têtes X-Forwarded-* uniquement depuis Traefik.
    # Le contrôleur Traefik de K3s est installé dans kube-system.
    http:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ${TRAEFIK_NAMESPACE}
  serviceMonitor:
    enabled: false
  resources:
    requests:
      cpu: "${KEYCLOAK_CPU_REQUEST}"
      memory: "${KEYCLOAK_MEMORY_REQUEST}"
    limits:
      cpu: "${KEYCLOAK_CPU_LIMIT}"
      memory: "${KEYCLOAK_MEMORY_LIMIT}"
EOF_KEYCLOAK
k apply -f "$MANIFEST"
info 'Attente de la condition Ready du CR Keycloak (maximum 30 minutes)'
for attempt in $(seq 1 180); do
  READY="$(k get keycloak "$KEYCLOAK_NAME" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
  [[ "$READY" == True ]] && break
  sleep 10
done
READY="$(k get keycloak "$KEYCLOAK_NAME" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
if [[ "$READY" != True ]]; then
  k get keycloak "$KEYCLOAK_NAME" -n "$KEYCLOAK_NAMESPACE" -o yaml || true
  k get pods -n "$KEYCLOAK_NAMESPACE" -o wide || true
  fail 'Keycloak n’a pas atteint Ready. Consulter les logs Operator, les événements et la connectivité PostgreSQL.'
fi
k get pods -n "$KEYCLOAK_NAMESPACE" -o wide
printf '\nSecret du compte administrateur initial : %s-initial-admin\n' "$KEYCLOAK_NAME"
printf 'Récupérer les identifiants localement, sans les copier dans des journaux ou tickets :\n'
printf "kubectl get secret %s-initial-admin -n %s -o jsonpath='{.data.username}' | base64 -d; echo\n" "$KEYCLOAK_NAME" "$KEYCLOAK_NAMESPACE"
printf "kubectl get secret %s-initial-admin -n %s -o jsonpath='{.data.password}' | base64 -d; echo\n" "$KEYCLOAK_NAME" "$KEYCLOAK_NAMESPACE"
