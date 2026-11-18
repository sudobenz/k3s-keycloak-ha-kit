#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/config.env"
[[ -f "$CONFIG_FILE" ]] || { echo "ERREUR: config.env introuvable: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ $EUID -ne 0 ]]; then
  echo "ERREUR: exécuter en root (sudo bash scripts/configure-host-protection.sh)." >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "ERREUR: impossible d'identifier la distribution." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) echo "ERREUR: ce script cible Ubuntu/Debian; distribution détectée: ${PRETTY_NAME:-inconnue}." >&2; exit 1 ;; esac
command -v apt-get >/dev/null 2>&1 || { echo "ERREUR: apt-get introuvable." >&2; exit 1; }

IGNORE_RAW="${FAIL2BAN_IGNORE_IPS:-}"
SSH_PORT="${FAIL2BAN_SSH_PORT:-ssh}"
if [[ -z "$IGNORE_RAW" ]]; then
  echo "ERREUR: renseigner FAIL2BAN_IGNORE_IPS dans config.env avec les IP/CIDR d'administration avant l'installation." >&2
  exit 1
fi
if [[ "$SSH_PORT" != "ssh" && ! "$SSH_PORT" =~ ^[0-9]{1,5}$ ]]; then
  echo "ERREUR: FAIL2BAN_SSH_PORT doit être 'ssh' ou un port TCP numérique." >&2
  exit 1
fi
if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  echo "ERREUR: port SSH hors plage." >&2
  exit 1
fi

# Accepte une liste d'adresses ou de réseaux CIDR séparés par des virgules.
IGNORE_NORMALIZED="$(python3 - "$IGNORE_RAW" <<'PY'
import ipaddress,sys
raw=sys.argv[1]
values=[x.strip() for x in raw.split(',') if x.strip()]
if not values:
    raise SystemExit('Aucune IP/CIDR de gestion valide.')
normalized=[]
for value in values:
    try:
        network=ipaddress.ip_network(value, strict=False)
        if network.prefixlen == 0:
            raise SystemExit(f'Un réseau /0 est interdit dans FAIL2BAN_IGNORE_IPS: {value}')
        normalized.append(str(network))
    except ValueError:
        raise SystemExit(f'Adresse ou réseau invalide dans FAIL2BAN_IGNORE_IPS: {value}')
print(' '.join(dict.fromkeys(normalized)))
PY
)" || exit 1

printf 'Installation des composants de protection SSH...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y fail2ban python3-systemd

install -d -m 0755 /etc/fail2ban/jail.d /etc/apt/apt.conf.d
TMP_JAIL="$(mktemp)"
cat > "$TMP_JAIL" <<EOF_JAIL
# Géré par le kit K3s HA. Protection SSH des hôtes uniquement.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${IGNORE_NORMALIZED}
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
EOF_JAIL
install -o root -g root -m 0644 "$TMP_JAIL" /etc/fail2ban/jail.d/99-k3s-host-ssh.local
rm -f "$TMP_JAIL"

# Les installations d'OS doivent être coordonnées au niveau du cluster.
# On autorise la mise à jour des listes, mais pas l'installation automatique
# des paquets ni un redémarrage autonome sur chaque membre etcd/CNPG.
TMP_APT="$(mktemp)"
cat > "$TMP_APT" <<'EOF_APT'
// Géré par le kit K3s HA : pas d'installation autonome non coordonnée.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
Unattended-Upgrade::Automatic-Reboot "false";
EOF_APT
install -o root -g root -m 0644 "$TMP_APT" /etc/apt/apt.conf.d/99-k3s-cluster-maintenance
rm -f "$TMP_APT"

fail2ban-client -t
systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client status sshd >/dev/null

printf '\nConfiguration appliquée.\n'
printf '  Jail actif : sshd (journal systemd)\n'
printf '  IP/CIDR ignorés : %s\n' "$IGNORE_NORMALIZED"
printf '  Port SSH : %s\n' "$SSH_PORT"
printf '  Installation automatique des mises à jour OS : désactivée\n'
printf '  Redémarrage automatique : désactivé\n'
printf '\nFail2ban utilise son action de bannissement système pour ajouter ses propres règles SSH; le script ne remplace ni ne vide le ruleset.\n'
printf 'Aucun pare-feu UFW/nftables global, aucune règle sshd et aucun service K3s/Longhorn/CNPG n’ont été modifiés.\n'
printf 'Exécuter ensuite : sudo bash scripts/check-host-protection.sh\n'
