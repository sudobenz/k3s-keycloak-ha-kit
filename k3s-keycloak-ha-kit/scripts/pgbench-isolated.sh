#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; validate_common
[[ "${1:-}" == RUN-ISOLATED-BENCHMARK ]] || fail "Opt-in : $0 RUN-ISOLATED-BENCHMARK [clients=4] [secondes=60]. Charge uniquement en qualification."
clients=${2:-4}; duration=${3:-60}
[[ "$clients" =~ ^[1-9][0-9]*$ && "$duration" =~ ^[1-9][0-9]*$ ]] || fail "Paramètres numériques positifs requis."
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
primary=$(k3s kubectl -n "$KEYCLOAK_NAMESPACE" get cluster "$CNPG_CLUSTER_NAME" -o jsonpath='{.status.currentPrimary}')
db="kit_bench_$(date +%s)_$$"
# Utilise une base de test isolée ; ne touche jamais à la base keycloak. Nettoyage garanti hors interruption SIGKILL.
cleanup() { k3s kubectl -n "$KEYCLOAK_NAMESPACE" exec "$primary" -c postgres -- dropdb -U postgres --if-exists "$db" || true; }
trap cleanup EXIT
k3s kubectl -n "$KEYCLOAK_NAMESPACE" exec "$primary" -c postgres -- createdb -U postgres "$db"
k3s kubectl -n "$KEYCLOAK_NAMESPACE" exec "$primary" -c postgres -- pgbench -U postgres -i -s 10 "$db"
mkdir -p "$ROOT_DIR/output"
k3s kubectl -n "$KEYCLOAK_NAMESPACE" exec "$primary" -c postgres -- pgbench -U postgres -c "$clients" -j 2 -T "$duration" -P 5 "$db"   2>&1 | tee "$ROOT_DIR/output/pgbench-$(date +%Y%m%d-%H%M%S).txt"
