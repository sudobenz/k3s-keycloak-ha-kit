#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
[[ $# -eq 1 ]] || fail "Usage : $0 1|2|3"
NODE_ID="$1"
load_config
load_secrets
validate_common
node_values "$NODE_ID"
if [[ "$NODE_ID" != "1" ]]; then
  require_value K3S_JOIN_TOKEN
fi
if [[ -e /var/lib/rancher/k3s/server/db || -f /etc/rancher/k3s/config.yaml ]]; then
  fail "Installation K3s existante détectée, même inactive : refus du bootstrap."
fi
if systemctl is-active --quiet k3s; then
  fail "K3s est déjà actif sur ${NODE_NAME}. Ce script est destiné au bootstrap initial ; ne le relancez pas sur un cluster existant."
fi

info "Préparation de ${NODE_NAME} (${NODE_IP})"
export_proxy_environment
configure_os_proxy
[[ -r /etc/os-release ]] || fail "/etc/os-release absent."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian)
    # Une CA de proxy d'entreprise doit être approuvée avant le premier apt-get update.
    if [[ -n "${CORPORATE_CA_FILE:-}" ]]; then
      command -v update-ca-certificates >/dev/null 2>&1 || fail 'update-ca-certificates absent : installer/préparer ca-certificates sur l’image système avant le bootstrap proxy TLS.'
      install_host_ca
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl iproute2 iptables conntrack socat python3 python3-yaml nfs-common open-iscsi cryptsetup dmsetup util-linux jq apache2-utils parted e2fsprogs git
    ;;
  rhel|rocky|almalinux|centos|fedora)
    if command -v dnf >/dev/null 2>&1; then
      if [[ -n "${CORPORATE_CA_FILE:-}" ]]; then
        command -v update-ca-trust >/dev/null 2>&1 || fail 'update-ca-trust absent : installer/préparer ca-certificates sur l’image système avant le bootstrap proxy TLS.'
        install_host_ca
      fi
      dnf install -y ca-certificates curl openssl iproute iptables conntrack-tools socat python3 python3-yaml nfs-utils iscsi-initiator-utils cryptsetup device-mapper util-linux jq httpd-tools parted e2fsprogs git
    else
      fail "dnf absent ; adaptation manuelle requise."
    fi
    ;;
  *) fail "Distribution non prise en charge automatiquement : ${ID:-inconnue}. Scripts prévus pour Debian/Ubuntu et RHEL/Rocky/AlmaLinux/Fedora avec systemd." ;;
esac
validate_common
modprobe iscsi_tcp
modprobe nfs
printf 'iscsi_tcp\nnfs\n' > /etc/modules-load.d/longhorn.conf
systemctl enable --now iscsid
if iscsiadm --version | grep -q '2.1.12'; then fail "open-iscsi 2.1.12 incompatible avec Longhorn 1.13 : installer <=2.1.11 ou >=2.1.13."; fi
install -d -m 0755 "$LONGHORN_DATA_PATH"
if [[ "$LONGHORN_REQUIRE_MOUNT" == true ]]; then
  mountpoint -q "$LONGHORN_DATA_PATH" || fail "Montez le disque Longhorn dédié sur $LONGHORN_DATA_PATH avant installation."
  data_source="$(findmnt -n -o SOURCE -T "$LONGHORN_DATA_PATH")"
  root_source="$(findmnt -n -o SOURCE -T /)"
  [[ "$data_source" != "$root_source" ]] || fail "Le stockage Longhorn utilise le même système de fichiers que / ; un disque dédié séparé est requis."
  # Compare les périphériques physiques sous-jacents (y compris partitions et LVM).
  data_disks="$(lsblk -sno NAME,TYPE "${data_source%%[*}" 2>/dev/null | awk '$2 == "disk" {print $1}' | sort -u || true)"
  root_disks="$(lsblk -sno NAME,TYPE "${root_source%%[*}" 2>/dev/null | awk '$2 == "disk" {print $1}' | sort -u || true)"
  if [[ -n "$data_disks" && -n "$root_disks" ]]; then
    shared_disks="$(comm -12 <(printf '%s\n' "$data_disks" | sed '/^$/d') <(printf '%s\n' "$root_disks" | sed '/^$/d') || true)"
    [[ -z "$shared_disks" ]] || fail "Le disque Longhorn partage un disque physique avec le système : ${shared_disks}. Prévoir un disque dédié indépendant."
  else
    warn "Impossible de résoudre les disques physiques via lsblk ; vérifiez manuellement que le volume Longhorn est sur un disque distinct du système."
  fi
fi
fs=$(findmnt -n -o FSTYPE -T "$LONGHORN_DATA_PATH")
[[ "$fs" == ext4 || "$fs" == xfs ]] || fail "Longhorn exige ici ext4/xfs ; détecté : $fs."

python3 - "$NODE_IP" "$KUBEVIP_INTERFACE" "$K3S_API_VIP" "$INGRESS_VIP" <<'PY'
import ipaddress,subprocess,sys
wanted=ipaddress.IPv4Address(sys.argv[1])
iface=sys.argv[2]
api_vip=ipaddress.IPv4Address(sys.argv[3])
ingress_vip=ipaddress.IPv4Address(sys.argv[4])
text=subprocess.check_output(["ip","-o","-4","addr","show","dev",iface],text=True)
node_networks=[]
for line in text.splitlines():
    for item in line.split():
        if "/" in item:
            try:
                net=ipaddress.IPv4Interface(item)
                if net.ip == wanted:
                    node_networks.append(net.network)
            except ValueError:
                pass
if not node_networks:
    raise SystemExit(f"L'adresse IP configurée {wanted} n'est pas portée par l'interface {iface}.")
if not any(api_vip in net and ingress_vip in net for net in node_networks):
    raise SystemExit(f"Les VIP {api_vip} et {ingress_vip} doivent appartenir au sous-réseau de {wanted} sur {iface} ({node_networks}).")
PY
check_interface

install -d -m 0755 /etc/rancher/k3s
install -d -m 0755 "$K3S_LOCAL_STORAGE_PATH"
write_k3s_proxy_env
install -d -m 0755 /etc/systemd/system/k3s.service.d
printf '[Unit]\nRequiresMountsFor=%s\n' "$LONGHORN_DATA_PATH" > /etc/systemd/system/k3s.service.d/20-longhorn-mount.conf

CONFIG_TMP="$(mktemp)"
trap 'rm -f "$CONFIG_TMP"' EXIT
cat > "$CONFIG_TMP" <<EOF_CONFIG
node-name: "${NODE_NAME}"
node-ip: "${NODE_IP}"
advertise-address: "${NODE_IP}"
tls-san:
  - "${K3S_API_VIP}"
cluster-cidr: "${K3S_POD_CIDR}"
service-cidr: "${K3S_SERVICE_CIDR}"
flannel-backend: "vxlan"
secrets-encryption: true
write-kubeconfig-mode: "0600"
default-local-storage-path: "${K3S_LOCAL_STORAGE_PATH}"
disable:
  - servicelb
  - metrics-server
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 8
EOF_CONFIG
if [[ "$NODE_ID" == "1" ]]; then
  printf 'cluster-init: true\n' >> "$CONFIG_TMP"
  printf 'token: "%s"\n' "$K3S_TOKEN" >> "$CONFIG_TMP"
else
  printf 'server: "https://%s:6443"\n' "$NODE1_IP" >> "$CONFIG_TMP"
  printf 'token: "%s"\n' "$K3S_JOIN_TOKEN" >> "$CONFIG_TMP"
fi
install -m 0600 "$CONFIG_TMP" /etc/rancher/k3s/config.yaml

export INSTALL_K3S_VERSION="$K3S_VERSION"
export INSTALL_K3S_EXEC="server"
export INSTALL_K3S_SKIP_SELINUX_RPM="false"
info "Installation de K3s ${K3S_VERSION} sur ${NODE_NAME}"
curl -fsSL https://get.k3s.io | sh -s - server
systemctl daemon-reload
systemctl enable --now k3s

info "Attente du service K3s"
for i in $(seq 1 90); do
  if systemctl is-active --quiet k3s; then
    break
  fi
  sleep 2
done
systemctl is-active --quiet k3s || fail "Le service K3s n'est pas actif. Consultez : journalctl -u k3s -n 200"

if [[ "$NODE_ID" == "1" ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  for i in $(seq 1 90); do
    if k3s kubectl get node "$NODE_NAME" >/dev/null 2>&1; then break; fi
    sleep 2
  done
  k3s kubectl get nodes -o wide
  SECURE_JOIN_TOKEN="$(cat /var/lib/rancher/k3s/server/token)"
  [[ "$SECURE_JOIN_TOKEN" == K10*::* ]] || fail "Le token sécurisé de jointure K3s n'a pas le format attendu. Consultez /var/lib/rancher/k3s/server/token."
  python3 - "$SECRETS_FILE" "$SECURE_JOIN_TOKEN" <<'PYTOKEN'
from pathlib import Path
import shlex,sys,os
p=Path(sys.argv[1]); lines=p.read_text().splitlines()
lines=[x for x in lines if not x.startswith('K3S_JOIN_TOKEN=')]
lines.append('K3S_JOIN_TOKEN='+shlex.quote(sys.argv[2]))
t=p.with_name('.secrets.env.tmp'); t.touch(mode=0o600); t.chmod(0o600)
t.write_text('\n'.join(lines)+'\n'); os.replace(t,p)
PYTOKEN
  echo "Nœud 1 initialisé. Le fichier secrets.env contient maintenant le token sécurisé de jointure : copiez-le sur les nœuds 2 et 3 avant leur installation."
else
  echo "Nœud ${NODE_ID} démarré. Vérifiez depuis le nœud 1 : k3s kubectl get nodes -o wide"
fi
