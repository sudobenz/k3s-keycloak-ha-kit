#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
validate_common

[[ -f /etc/rancher/k3s/k3s.yaml ]] || fail "À exécuter sur le nœud 1 (kubeconfig local absent)."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export_proxy_environment
if k3s kubectl -n kube-system get daemonset kube-vip-ds >/dev/null 2>&1; then
  fail "DaemonSet kube-vip-ds déjà présent : ce script est réservé au bootstrap initial. Utilisez upgrade/14-upgrade-kube-vip.sh pour mettre à jour l'image en conservant le manifeste existant."
fi

info "Vérification des trois nœuds avant le déploiement des VIP"
k3s kubectl wait --for=condition=Ready node/"$NODE1_NAME" --timeout=180s
k3s kubectl wait --for=condition=Ready node/"$NODE2_NAME" --timeout=180s
k3s kubectl wait --for=condition=Ready node/"$NODE3_NAME" --timeout=180s

# L'image est téléchargée par le runtime local, avec le proxy du service K3s.
IMAGE="ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION}"
CTR_ADDRESS="/run/k3s/containerd/containerd.sock"
info "Téléchargement de ${IMAGE}"
k3s ctr --address "$CTR_ADDRESS" --namespace k8s.io image pull "$IMAGE"

install -d -m 0755 /var/lib/rancher/k3s/server/manifests
RBAC_TMP="$(mktemp)"
VIP_TMP="$(mktemp)"
trap 'rm -f "$RBAC_TMP" "$VIP_TMP"' EXIT
curl -fsSL https://kube-vip.io/manifests/rbac.yaml -o "$RBAC_TMP"
install -m 0644 "$RBAC_TMP" /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml

info "Génération du DaemonSet kube-vip"
k3s ctr --address "$CTR_ADDRESS" --namespace k8s.io run --rm --net-host "$IMAGE" vip \
  /kube-vip manifest daemonset \
  --interface "$KUBEVIP_INTERFACE" \
  --address "$K3S_API_VIP" \
  --inCluster --taint --controlplane --services --arp --leaderElection --servicesElection > "$VIP_TMP"
install -m 0644 "$VIP_TMP" /var/lib/rancher/k3s/server/manifests/kube-vip-ds.yaml

k3s kubectl apply -f /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml
k3s kubectl apply -f /var/lib/rancher/k3s/server/manifests/kube-vip-ds.yaml
k3s kubectl -n kube-system rollout status daemonset/kube-vip-ds --timeout=300s

info "Attente du service Traefik et affectation de l'adresse d'entrée"
for i in $(seq 1 90); do
  if k3s kubectl -n kube-system get svc traefik >/dev/null 2>&1; then break; fi
  sleep 2
done
k3s kubectl -n kube-system get svc traefik >/dev/null 2>&1 || fail "Le service Traefik n'existe pas. Vérifiez que le chart Traefik intégré K3s est actif."
k3s kubectl -n kube-system annotate svc traefik "kube-vip.io/loadbalancerIPs=${INGRESS_VIP}" --overwrite

# Kubeconfig de gestion via le VIP API ; le kubeconfig original reste intact.
install -d -m 0700 "${ROOT_DIR}/output"
cp /etc/rancher/k3s/k3s.yaml "${ROOT_DIR}/output/kubeconfig"
sed -i "s#https://127.0.0.1:6443#https://${K3S_API_VIP}:6443#" "${ROOT_DIR}/output/kubeconfig"
chmod 0600 "${ROOT_DIR}/output/kubeconfig"

info "Contrôle des services"
k3s kubectl -n kube-system get pods -o wide
k3s kubectl -n kube-system get svc traefik -o wide
printf '\nVIP API : %s:6443\nVIP Ingress : %s (80/443)\nKubeconfig de gestion : %s\n' "$K3S_API_VIP" "$INGRESS_VIP" "${ROOT_DIR}/output/kubeconfig"
