#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
SECRETS_FILE="${ROOT_DIR}/secrets.env"

fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf 'AVERTISSEMENT: %s\n' "$*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Commande requise absente : $1"; }
require_root() { [[ "$(id -u)" -eq 0 ]] || fail 'Exécuter ce script en root.'; }
require_value() { local n="$1"; [[ -n "${!n:-}" && "${!n}" != *A_COMPLETER* ]] || fail "Paramètre obligatoire non renseigné : $n"; }

load_config() {
  [[ -r "$CONFIG_FILE" ]] || fail "Fichier absent ou illisible : $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  if [[ -r "$SECRETS_FILE" ]]; then
    chmod 600 "$SECRETS_FILE" 2>/dev/null || true
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
  fi
}

load_secrets() {
  [[ -r "$SECRETS_FILE" ]] || fail "Fichier secrets.env absent. Exécutez scripts/00-generate-secrets.sh une seule fois."
  chmod 600 "$SECRETS_FILE" 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  for name in K3S_TOKEN KEYCLOAK_DB_PASSWORD; do
    [[ -n "${!name:-}" && "${!name}" != GENERATED ]] || fail "Secret ${name} absent/invalide dans secrets.env."
  done
}

k() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl "$@"
  elif command -v k3s >/dev/null 2>&1; then
    k3s kubectl "$@"
  else
    fail 'Ni kubectl ni k3s ne sont disponibles.'
  fi
}

require_cluster() {
  if [[ -n "${KUBECONFIG:-}" && -r "$KUBECONFIG" ]]; then :
  elif [[ -r /etc/rancher/k3s/k3s.yaml ]] && command -v k3s >/dev/null 2>&1; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  else
    fail "Kubeconfig absent/illisible : ${KUBECONFIG:-non défini}. Exécutez depuis le nœud 1 ou configurez KUBECONFIG."
  fi
  k cluster-info >/dev/null 2>&1 || fail 'API Kubernetes inaccessible.'
}

validate_ip() { python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1])
except ValueError: raise SystemExit(1)
PY
}
validate_cidr() { python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError: raise SystemExit(1)
PY
}
validate_quantity() { [[ "$1" =~ ^[1-9][0-9]*(Ki|Mi|Gi|Ti)$ ]]; }

validate_common() {
  local n
  for n in NODE1_NAME NODE1_IP NODE2_NAME NODE2_IP NODE3_NAME NODE3_IP K3S_VERSION K3S_POD_CIDR K3S_SERVICE_CIDR K3S_LOCAL_STORAGE_PATH K3S_API_VIP INGRESS_VIP KUBEVIP_INTERFACE KUBEVIP_VERSION HELM_VERSION LONGHORN_VERSION CNPG_VERSION POSTGRES_IMAGE CERT_MANAGER_VERSION KEYCLOAK_VERSION KEYCLOAK_OPERATOR_REF KEYCLOAK_NAMESPACE CNPG_NAMESPACE CERT_MANAGER_NAMESPACE INGRESS_CLASS PG_STORAGE_CLASS PG_STORAGE_SIZE PG_SYNC_MODE CNPG_CLUSTER_NAME CNPG_INSTANCES KEYCLOAK_DB_NAME KEYCLOAK_DB_USER KEYCLOAK_DB_SECRET KEYCLOAK_NAME KEYCLOAK_FQDN KEYCLOAK_REPLICAS KEYCLOAK_TLS_MODE KEYCLOAK_TLS_SECRET TRAEFIK_ENABLE_HTTP; do
    require_value "$n"
  done
  for n in NODE1_IP NODE2_IP NODE3_IP K3S_API_VIP INGRESS_VIP; do validate_ip "${!n}" || fail "$n n'est pas une IPv4 valide : ${!n}"; done
  for n in K3S_POD_CIDR K3S_SERVICE_CIDR; do validate_cidr "${!n}" || fail "$n n'est pas un CIDR valide : ${!n}"; done
  python3 - "$K3S_POD_CIDR" "$K3S_SERVICE_CIDR" <<'PY'
import ipaddress,sys
p,s=(ipaddress.ip_network(x,strict=False) for x in sys.argv[1:])
if p.version != 4 or s.version != 4 or p.overlaps(s): raise SystemExit('CIDR Pod/Service invalides ou chevauchants.')
PY
  [[ "$K3S_VERSION" =~ ^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || fail 'K3S_VERSION doit être une version exacte v1.x.y+k3sN.'
  [[ "$HELM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'HELM_VERSION invalide.'
  [[ "$KEYCLOAK_VERSION" == "$KEYCLOAK_OPERATOR_REF" ]] || fail 'KEYCLOAK_VERSION et KEYCLOAK_OPERATOR_REF doivent être alignés.'
  [[ "$KEYCLOAK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'KEYCLOAK_VERSION doit être épinglée au format X.Y.Z.'
  [[ "$CNPG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'CNPG_VERSION doit être une version exacte X.Y.Z; vérifier la compatibilité Kubernetes avant upgrade.'
  [[ "$LONGHORN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'LONGHORN_VERSION doit être une version exacte X.Y.Z; suivre le chemin Longhorn supporté avant upgrade.'
  for n in KEYCLOAK_FQDN LONGHORN_FQDN; do [[ "${!n}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "${!n}" != *..* ]] || fail "$n invalide : ${!n}"; done
  [[ "$KEYCLOAK_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail 'KEYCLOAK_NAMESPACE invalide.'
  [[ "$CNPG_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail 'CNPG_NAMESPACE invalide.'
  [[ "$CERT_MANAGER_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail 'CERT_MANAGER_NAMESPACE invalide.'
  [[ "$KEYCLOAK_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail 'KEYCLOAK_NAME invalide.'
  [[ "$KEYCLOAK_REPLICAS" == 3 && "$CNPG_INSTANCES" == 3 ]] || fail 'Le profil HA du kit requiert 3 pods Keycloak et 3 instances CNPG.'
  [[ "$K3S_API_VIP" != "$INGRESS_VIP" ]] || fail 'Les deux VIP doivent être distinctes.'
  [[ "$PG_SYNC_MODE" == async || "$PG_SYNC_MODE" == preferred || "$PG_SYNC_MODE" == required ]] || fail 'PG_SYNC_MODE doit être async, preferred ou required.'
  validate_quantity "$PG_STORAGE_SIZE" || fail 'PG_STORAGE_SIZE invalide.'
  [[ "$PG_MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ && "$KEYCLOAK_DB_POOL_MAX" =~ ^[1-9][0-9]*$ && "$PG_CPU_REQUEST" =~ ^[0-9]+([.][0-9]+)?(m)?$ ]] || fail 'Paramètres PostgreSQL numériques invalides.'
  [[ -n "$PG_MEMORY_REQUEST" && -n "$KEYCLOAK_CPU_REQUEST" && -n "$KEYCLOAK_MEMORY_REQUEST" && -n "$KEYCLOAK_CPU_LIMIT" && -n "$KEYCLOAK_MEMORY_LIMIT" ]] || fail 'Ressources CPU/mémoire non renseignées.'
  [[ "$CERT_MANAGER_CERT_DURATION" =~ ^[1-9][0-9]*h$ && "$CERT_MANAGER_RENEW_BEFORE" =~ ^[1-9][0-9]*h$ ]] || fail 'Durée cert-manager et renewBefore doivent être exprimés en heures.'
  (( KEYCLOAK_DB_POOL_MAX * KEYCLOAK_REPLICAS < PG_MAX_CONNECTIONS )) || fail 'KEYCLOAK_DB_POOL_MAX x KEYCLOAK_REPLICAS doit rester inférieur à PG_MAX_CONNECTIONS.'
  [[ "$KEYCLOAK_TLS_MODE" == selfsigned || "$KEYCLOAK_TLS_MODE" == files || "$KEYCLOAK_TLS_MODE" == cert-manager ]] || fail 'KEYCLOAK_TLS_MODE doit être selfsigned, files ou cert-manager.'
  [[ "$TRAEFIK_ENABLE_HTTP" == true || "$TRAEFIK_ENABLE_HTTP" == false ]] || fail 'TRAEFIK_ENABLE_HTTP doit être true ou false.'
  [[ "$LONGHORN_REQUIRE_MOUNT" == true || "$LONGHORN_REQUIRE_MOUNT" == false ]] || fail 'LONGHORN_REQUIRE_MOUNT doit être true ou false.'
  [[ "$TLS_FORCE_REPLACE" == true || "$TLS_FORCE_REPLACE" == false ]] || fail 'TLS_FORCE_REPLACE doit être true ou false.'
  [[ "$HEADLAMP_INSTALL" == true || "$HEADLAMP_INSTALL" == false ]] || fail 'HEADLAMP_INSTALL doit être true ou false.'
  [[ "$PORTAINER_USE_PROXY" == true || "$PORTAINER_USE_PROXY" == false ]] || fail 'PORTAINER_USE_PROXY doit être true ou false.'
  [[ "$CERT_VALIDITY_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] || fail 'CERT_VALIDITY_DAYS doit être un entier positif (max. 9999). '
  (( CERT_VALIDITY_DAYS <= 825 )) || warn 'Un certificat autosigné valable plus de 825 jours peut être refusé par certains clients ; réduire CERT_VALIDITY_DAYS si nécessaire.'
  [[ "$NODE1_NAME" != "$NODE2_NAME" && "$NODE1_NAME" != "$NODE3_NAME" && "$NODE2_NAME" != "$NODE3_NAME" ]] || fail 'Les noms de nœuds doivent être distincts.'
  [[ "$NODE1_IP" != "$NODE2_IP" && "$NODE1_IP" != "$NODE3_IP" && "$NODE2_IP" != "$NODE3_IP" ]] || fail 'Les IP des nœuds doivent être distinctes.'
  [[ "$KUBEVIP_INTERFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail 'KUBEVIP_INTERFACE invalide.'
  [[ "$K3S_LOCAL_STORAGE_PATH" == /* && "$LONGHORN_DATA_PATH" == /* ]] || fail 'Les chemins de stockage doivent être absolus.'
  [[ "$PG_SYNC_MODE" != required ]] || warn 'PG_SYNC_MODE=required privilégie la durabilité mais peut bloquer les écritures si aucun standby synchrone ne peut être utilisé.'
  if [[ "$KEYCLOAK_TLS_MODE" == files ]]; then [[ -r "$CERT_FILE" && -r "$KEY_FILE" ]] || fail 'CERT_FILE/KEY_FILE doivent être renseignés et lisibles en mode files.'; fi
  if [[ "$KEYCLOAK_TLS_MODE" == cert-manager ]]; then require_value CERT_MANAGER_ISSUER_NAME; [[ "$CERT_MANAGER_ISSUER_KIND" == Issuer || "$CERT_MANAGER_ISSUER_KIND" == ClusterIssuer ]] || fail 'CERT_MANAGER_ISSUER_KIND doit être Issuer ou ClusterIssuer.'; fi
}

node_values() {
  case "$1" in 1) NODE_NAME="$NODE1_NAME"; NODE_IP="$NODE1_IP";; 2) NODE_NAME="$NODE2_NAME"; NODE_IP="$NODE2_IP";; 3) NODE_NAME="$NODE3_NAME"; NODE_IP="$NODE3_IP";; *) fail 'Identifiant de nœud attendu : 1, 2 ou 3.';; esac
  export NODE_NAME NODE_IP
}

make_no_proxy() {
  local base="${NO_PROXY:-}" internal
  internal="localhost,127.0.0.1,::1,.svc,.svc.cluster.local,.cluster.local,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local,${K3S_POD_CIDR},${K3S_SERVICE_CIDR},${NODE1_NAME},${NODE1_IP},${NODE2_NAME},${NODE2_IP},${NODE3_NAME},${NODE3_IP},${K3S_API_VIP},${INGRESS_VIP},${KEYCLOAK_FQDN},${CNPG_CLUSTER_NAME}-rw.${KEYCLOAK_NAMESPACE}.svc.cluster.local"
  [[ -z "$base" ]] && printf '%s' "$internal" || printf '%s,%s' "$base" "$internal"
}
export_proxy_environment() {
  local np; np="$(make_no_proxy)"
  [[ -z "${HTTP_PROXY:-}" ]] || export HTTP_PROXY http_proxy="$HTTP_PROXY"
  [[ -z "${HTTPS_PROXY:-}" ]] || export HTTPS_PROXY https_proxy="$HTTPS_PROXY"
  export NO_PROXY="$np" no_proxy="$np"
}
systemd_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
write_k3s_proxy_env() {
  local np; np="$(make_no_proxy)"
  install -d -m 0755 /etc/systemd/system
  {
    [[ -z "${HTTP_PROXY:-}" ]] || printf 'HTTP_PROXY="%s"\nhttp_proxy="%s"\n' "$(systemd_escape "$HTTP_PROXY")" "$(systemd_escape "$HTTP_PROXY")"
    [[ -z "${HTTPS_PROXY:-}" ]] || printf 'HTTPS_PROXY="%s"\nhttps_proxy="%s"\n' "$(systemd_escape "$HTTPS_PROXY")" "$(systemd_escape "$HTTPS_PROXY")"
    printf 'NO_PROXY="%s"\nno_proxy="%s"\n' "$(systemd_escape "$np")" "$(systemd_escape "$np")"
  } > /etc/systemd/system/k3s.service.env
  chmod 600 /etc/systemd/system/k3s.service.env
}
configure_os_proxy() {
  [[ -r /etc/os-release ]] || fail '/etc/os-release absent.'; . /etc/os-release
  if [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]]; then
    case "${ID:-}" in
      ubuntu|debian) install -d -m 0755 /etc/apt/apt.conf.d; { [[ -z "${HTTP_PROXY:-}" ]] || printf 'Acquire::http::Proxy "%s";\n' "$HTTP_PROXY"; [[ -z "${HTTPS_PROXY:-}" ]] || printf 'Acquire::https::Proxy "%s";\n' "$HTTPS_PROXY"; } > /etc/apt/apt.conf.d/90-corporate-proxy; chmod 600 /etc/apt/apt.conf.d/90-corporate-proxy;;
      rhel|rocky|almalinux|centos|fedora) install -d -m 0755 /etc/dnf/dnf.conf.d; { printf '[main]\n'; printf 'proxy=%s\n' "${HTTPS_PROXY:-$HTTP_PROXY}"; } > /etc/dnf/dnf.conf.d/90-corporate-proxy.conf; chmod 600 /etc/dnf/dnf.conf.d/90-corporate-proxy.conf;;
      *) warn "Proxy du gestionnaire de paquets non configuré pour ${ID:-inconnu}.";;
    esac
  fi
}
install_host_ca() {
  [[ -n "${CORPORATE_CA_FILE:-}" ]] || return 0
  [[ -r "$CORPORATE_CA_FILE" ]] || fail "CORPORATE_CA_FILE illisible : $CORPORATE_CA_FILE"
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) install -d -m 0755 /usr/local/share/ca-certificates; install -m 0644 "$CORPORATE_CA_FILE" /usr/local/share/ca-certificates/corporate-proxy.crt; update-ca-certificates;;
    rhel|rocky|almalinux|centos|fedora) install -d -m 0755 /etc/pki/ca-trust/source/anchors; install -m 0644 "$CORPORATE_CA_FILE" /etc/pki/ca-trust/source/anchors/corporate-proxy.crt; update-ca-trust extract;;
    *) fail "Installation CA non prévue pour ${ID:-inconnu}.";;
  esac
}
check_interface() { ip link show dev "$KUBEVIP_INTERFACE" >/dev/null 2>&1 || fail "Interface réseau absente : $KUBEVIP_INTERFACE"; }
