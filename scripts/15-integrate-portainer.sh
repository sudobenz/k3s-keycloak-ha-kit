#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
PORTAINER_NAMESPACE="${PORTAINER_NAMESPACE:-portainer}"
PORTAINER_USE_PROXY="${PORTAINER_USE_PROXY:-false}"
MANIFEST="${1:-${ROOT_DIR}/portainer/portainer-agent-edge-k8s.yaml}"
[[ "$PORTAINER_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail 'PORTAINER_NAMESPACE invalide.'
[[ "$PORTAINER_USE_PROXY" == true || "$PORTAINER_USE_PROXY" == false ]] || fail 'PORTAINER_USE_PROXY doit être true ou false.'
[[ -s "$MANIFEST" && -r "$MANIFEST" ]] || fail "Manifeste absent : ${MANIFEST}. Générer le manifeste Kubernetes Edge Agent Standard depuis Portainer puis le placer ici."
command -v k3s >/dev/null 2>&1 || fail 'Exécuter ce script sur un nœud K3s.'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl cluster-info >/dev/null 2>&1 || fail 'API Kubernetes inaccessible.'
ready_nodes="$(k3s kubectl get nodes --no-headers | awk '$2 ~ /^Ready/ {n++} END {print n+0}')"
(( ready_nodes == 3 )) || fail "Cluster non entièrement Ready : ${ready_nodes}/3 nœuds."
grep -Eqi 'portainer/agent|portainer-agent|edge-agent' "$MANIFEST" || fail 'Le manifeste ne semble pas être celui de Portainer Edge Agent.'
k3s kubectl create namespace "$PORTAINER_NAMESPACE" --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
k3s kubectl apply --dry-run=server -f "$MANIFEST" >/dev/null
k3s kubectl apply -f "$MANIFEST"
workloads=''
for _ in $(seq 1 60); do workloads="$(k3s kubectl -n "$PORTAINER_NAMESPACE" get deployments,daemonsets -o name | grep -Ei 'agent' || true)"; [[ -n "$workloads" ]] && break; sleep 2; done
[[ -n "$workloads" ]] || fail "Aucun workload Agent détecté dans ${PORTAINER_NAMESPACE}. Vérifier le namespace du manifeste Portainer."
if [[ "$PORTAINER_USE_PROXY" == true ]]; then
  [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]] || fail 'Proxy activé mais HTTP_PROXY/HTTPS_PROXY vides.'
  np="$(make_no_proxy)"; args=()
  [[ -z "${HTTP_PROXY:-}" ]] || args+=("HTTP_PROXY=${HTTP_PROXY}" "http_proxy=${HTTP_PROXY}")
  [[ -z "${HTTPS_PROXY:-}" ]] || args+=("HTTPS_PROXY=${HTTPS_PROXY}" "https_proxy=${HTTPS_PROXY}")
  args+=("NO_PROXY=${np}" "no_proxy=${np}")
  while IFS= read -r workload; do [[ -z "$workload" ]] || k3s kubectl -n "$PORTAINER_NAMESPACE" set env "$workload" "${args[@]}" >/dev/null; done <<< "$workloads"
fi
while IFS= read -r workload; do [[ -z "$workload" ]] || k3s kubectl -n "$PORTAINER_NAMESPACE" rollout status "$workload" --timeout=600s; done <<< "$workloads"
k3s kubectl -n "$PORTAINER_NAMESPACE" get pods -o wide
echo 'Portainer Edge Agent appliqué. Le serveur Portainer reste externe à ce kit.'
