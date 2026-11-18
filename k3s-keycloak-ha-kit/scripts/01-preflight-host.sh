#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; load_secrets; validate_common
[[ $# -eq 1 ]] || fail "Usage : $0 1|2|3"
node_values "$1"
require_cmd ip; require_cmd lsblk; require_cmd findmnt
[[ -r /etc/os-release ]] || fail '/etc/os-release absent.'
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 ]] || warn "Kit préparé prioritairement pour Ubuntu 26.04 ; détecté : ${PRETTY_NAME:-inconnu}. Qualification OS requise."
[[ "$(hostname -s)" == "$NODE_NAME" ]] || warn "Hostname système $(hostname -s) différent de NODE_NAME=${NODE_NAME}. Vérifier avant bootstrap."
ip -o -4 addr show dev "$KUBEVIP_INTERFACE" | grep -Fq "$NODE_IP/" || fail "IP ${NODE_IP} absente de l'interface ${KUBEVIP_INTERFACE}."
python3 - "$NODE_IP" "$KUBEVIP_INTERFACE" "$K3S_API_VIP" "$INGRESS_VIP" <<'PY'
import ipaddress,subprocess,sys
wanted=ipaddress.IPv4Address(sys.argv[1]); iface=sys.argv[2]
vips=[ipaddress.IPv4Address(sys.argv[3]),ipaddress.IPv4Address(sys.argv[4])]
text=subprocess.check_output(['ip','-o','-4','addr','show','dev',iface],text=True)
nets=[]
for line in text.splitlines():
  for token in line.split():
    if '/' in token:
      try:
        x=ipaddress.IPv4Interface(token)
        if x.ip==wanted: nets.append(x.network)
      except ValueError: pass
if not nets: raise SystemExit('Adresse node IP non portée par interface configurée.')
if not any(all(v in n for v in vips) for n in nets): raise SystemExit('Les VIP doivent être dans le même sous-réseau IPv4 que l’adresse du nœud.')
PY
if [[ "$LONGHORN_REQUIRE_MOUNT" == true ]]; then
  mountpoint -q "$LONGHORN_DATA_PATH" || fail "Point de montage Longhorn absent : ${LONGHORN_DATA_PATH}. Préparer le disque avant K3s."
  fs="$(findmnt -n -o FSTYPE -T "$LONGHORN_DATA_PATH")"
  [[ "$fs" == ext4 || "$fs" == xfs ]] || fail "Longhorn exige ext4/xfs ; détecté : ${fs}."
  data_src="$(findmnt -n -o SOURCE -T "$LONGHORN_DATA_PATH")"; root_src="$(findmnt -n -o SOURCE -T /)"
  [[ "$data_src" != "$root_src" ]] || fail 'Le disque Longhorn ne doit pas partager le système de fichiers racine.'
fi
if systemctl is-active --quiet k3s || systemctl is-active --quiet k3s-agent; then fail 'Un service K3s est déjà actif. Ce contrôle cible un hôte vierge avant bootstrap.'; fi
if [[ -e /var/lib/rancher/k3s/server/db || -f /etc/rancher/k3s/config.yaml ]]; then fail 'Des traces d’installation K3s existent. Ne pas réinitialiser sans procédure de nettoyage dédiée.'; fi
printf '\nPréflight hôte %s réussi. Interface=%s IP=%s Longhorn=%s\n' "$NODE_NAME" "$KUBEVIP_INTERFACE" "$NODE_IP" "${LONGHORN_DATA_PATH}"
echo 'Vérifier aussi le pare-feu, DNS, NTP, route, MTU et accès aux dépôts/registries avant l’installation.'
