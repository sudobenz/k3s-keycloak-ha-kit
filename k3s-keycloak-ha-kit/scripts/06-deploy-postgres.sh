#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; load_secrets; validate_common; require_cluster
k get crd clusters.postgresql.cnpg.io >/dev/null || fail 'CloudNativePG absent : exécuter 03-install-cnpg.sh.'
k create namespace "$KEYCLOAK_NAMESPACE" --dry-run=client -o yaml | k apply -f -
if k get cluster "$CNPG_CLUSTER_NAME" -n "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1; then
  k get secret "$KEYCLOAK_DB_SECRET" -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail 'Cluster DB existant mais Secret credentials absent ; restauration manuelle requise.'
  STORED_PASS="$(k get secret "$KEYCLOAK_DB_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
  [[ "$STORED_PASS" == "$KEYCLOAK_DB_PASSWORD" ]] || fail 'Le mot de passe secrets.env ne correspond pas au Secret existant. Aucun écrasement effectué.'
  warn 'Cluster CNPG déjà existant et credentials concordants : aucun manifeste n’est réappliqué.'
  k wait --for=condition=Ready "cluster/${CNPG_CLUSTER_NAME}" -n "$KEYCLOAK_NAMESPACE" --timeout=1800s
  exit 0
fi
k create secret generic "$KEYCLOAK_DB_SECRET" -n "$KEYCLOAK_NAMESPACE" \
  --from-literal=username="$KEYCLOAK_DB_USER" --from-literal=password="$KEYCLOAK_DB_PASSWORD" \
  --dry-run=client -o yaml | k apply -f -
case "$PG_SYNC_MODE" in
  async) SYNC_BLOCK='' ;;
  preferred) SYNC_BLOCK=$'    synchronous:\n      method: any\n      number: 1\n      dataDurability: preferred\n      failoverQuorum: true' ;;
  required) SYNC_BLOCK=$'    synchronous:\n      method: any\n      number: 1\n      dataDurability: required\n      failoverQuorum: true' ;;
esac
mkdir -p "$ROOT_DIR/output"
MANIFEST="$ROOT_DIR/output/keycloak-postgres.yaml"
cat > "$MANIFEST" <<EOF_YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CNPG_CLUSTER_NAME}
  namespace: ${KEYCLOAK_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: keycloak
spec:
  instances: ${CNPG_INSTANCES}
  imageName: "${POSTGRES_IMAGE}"
  resources:
    requests:
      cpu: "${PG_CPU_REQUEST}"
      memory: "${PG_MEMORY_REQUEST}"
  storage:
    storageClass: "${PG_STORAGE_CLASS}"
    size: "${PG_STORAGE_SIZE}"
  affinity:
    enablePodAntiAffinity: true
    podAntiAffinityType: required
    topologyKey: kubernetes.io/hostname
  bootstrap:
    initdb:
      database: "${KEYCLOAK_DB_NAME}"
      owner: "${KEYCLOAK_DB_USER}"
      secret:
        name: "${KEYCLOAK_DB_SECRET}"
  postgresql:
    parameters:
      max_connections: "${PG_MAX_CONNECTIONS}"
${SYNC_BLOCK}
EOF_YAML
k apply -f "$MANIFEST"
k wait --for=condition=Ready "cluster/${CNPG_CLUSTER_NAME}" -n "$KEYCLOAK_NAMESPACE" --timeout=1800s
k get pods -n "$KEYCLOAK_NAMESPACE" -l "cnpg.io/cluster=${CNPG_CLUSTER_NAME}" -o wide
k get cluster "$CNPG_CLUSTER_NAME" -n "$KEYCLOAK_NAMESPACE" -o wide
