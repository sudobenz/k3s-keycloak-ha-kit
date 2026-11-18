#!/usr/bin/env bash
# Mise à niveau d'un serveur K3s à la fois. À lancer localement sur le nœud ciblé.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_root; require_cluster; require_cmd curl; require_cmd systemctl
[[ $# -ge 4 ]] || fail "Usage: $0 <NODE_NAME> <K3S_TARGET_vX.Y.Z+k3sN> --plan|--apply --backup-evidence <fichier>"
TARGET_NODE="$1"; TARGET_VERSION="$2"; APPLY="$3"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
EVIDENCE="${5:-}"; [[ "${4:-}" == --backup-evidence && -n "$EVIDENCE" ]] || fail '--backup-evidence obligatoire.'
verify_backup_evidence "$EVIDENCE" yes yes yes
case "$TARGET_NODE" in "$NODE1_NAME"|"$NODE2_NAME"|"$NODE3_NAME") ;; *) fail "Nœud non configuré: $TARGET_NODE";; esac
[[ "$(hostname -s)" == "$TARGET_NODE" ]] || fail "À exécuter localement sur $TARGET_NODE (hostname actuel: $(hostname -s)); le script ne met pas à niveau un hôte distant."
[[ "$TARGET_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || fail 'La cible doit être une version K3s exacte vX.Y.Z+k3sN.'
LOCAL_CURRENT="$(k get node "$TARGET_NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}')"
[[ "$LOCAL_CURRENT" == v*+k3s* ]] || fail "Version K3s/Kubelet courante illisible: $LOCAL_CURRENT"
python3 - "$LOCAL_CURRENT" "$TARGET_VERSION" <<'PYK3S'
import re,sys

def p(s):
 m=re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)\+k3s(\d+)',s)
 if not m: raise SystemExit(f'Version K3s invalide: {s}')
 return tuple(map(int,m.groups()))
a,b=p(sys.argv[1]),p(sys.argv[2])
if b<=a: raise SystemExit('La cible K3s doit être supérieure à la version de ce nœud.')
if a[0]!=b[0] or b[1] not in (a[1],a[1]+1): raise SystemExit('K3s: saut de minor/major refusé; passer par chaque minor successif après validation Kubernetes/K3s.')
PYK3S
full_preflight
assert_services_election_enabled
# Les kits installent K3s avec INSTALL_K3S_EXEC=server et placent les options
# durables dans config.yaml. Refuser de réécrire un service local personnalisé.
SERVICE_ARGS="$(systemctl show -p ExecStart --value k3s)"
[[ "$SERVICE_ARGS" == *"k3s server"* ]] || fail "ExecStart K3s inattendu: $SERVICE_ARGS. Vérifier manuellement les paramètres d'installation avant upgrade."
if grep -Eq -- '--(disable|node-ip|advertise-address|cluster-cidr|service-cidr|flannel-backend|secrets-encryption|tls-san|token|server)(=|[[:space:]])' <<<"$SERVICE_ARGS"; then
  fail "Des paramètres K3s semblent être passés dans ExecStart plutôt que config.yaml. Mise à niveau automatisée refusée pour ne pas les perdre."
fi
printf 'Nœud local: %s; version: %s -> %s.\n' "$TARGET_NODE" "$LOCAL_CURRENT" "$TARGET_VERSION"
if [[ "$APPLY" == --plan ]]; then
  echo 'PLAN: snapshot etcd local, cordon/drain en excluant les pods CNPG strict-local, upgrade exact INSTALL_K3S_VERSION, attente Kubernetes+Longhorn, uncordon et post-contrôle.'
  echo 'PLAN SEUL : aucune modification.'; exit 0
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$BACKUP_DIR"
cp -a /etc/rancher/k3s/config.yaml "$BACKUP_DIR/k3s-config-${TARGET_NODE}-${STAMP}.yaml"
if [[ -f /etc/systemd/system/k3s.service.env ]]; then cp -a /etc/systemd/system/k3s.service.env "$BACKUP_DIR/k3s.service.env-${TARGET_NODE}-${STAMP}"; fi
if [[ -f /etc/systemd/system/k3s.service ]]; then cp -a /etc/systemd/system/k3s.service "$BACKUP_DIR/k3s.service-${TARGET_NODE}-${STAMP}"; fi
if [[ -d /etc/systemd/system/k3s.service.d ]]; then cp -a /etc/systemd/system/k3s.service.d "$BACKUP_DIR/k3s-service-dropins-${TARGET_NODE}-${STAMP}"; fi
SNAPSHOT="pre-upgrade-${TARGET_NODE}-${STAMP}"
info "Création d'un snapshot etcd local: $SNAPSHOT"
k3s etcd-snapshot save --name "$SNAPSHOT"
k3s etcd-snapshot list | grep -F "$SNAPSHOT" >/dev/null || fail 'Snapshot etcd non retrouvé dans k3s etcd-snapshot list.'
# Le fichier de preuves doit référencer la copie hors hôte de ce snapshot; le snapshot local seul n'est pas un PRA.
prepare_node_for_maintenance "$TARGET_NODE"
TMP_INSTALLER="$(mktemp)"; trap 'rm -f "$TMP_INSTALLER"' EXIT
# Récupérer uniquement les paramètres proxy nécessaires au téléchargement; ne pas
# exporter les secrets applicatifs dans l'environnement du programme d'installation.
load_kit_proxy_environment
curl -fsSL https://get.k3s.io -o "$TMP_INSTALLER" || fail 'Téléchargement du script officiel K3s impossible (vérifier DNS/proxy/CA).'
export INSTALL_K3S_VERSION="$TARGET_VERSION"
export INSTALL_K3S_EXEC="server"
export INSTALL_K3S_SKIP_SELINUX_RPM="false"
export INSTALL_K3S_SKIP_START="true"
info "Installation préparée de $TARGET_VERSION sur $TARGET_NODE (config.yaml existant conservé, redémarrage reporté)."
sh "$TMP_INSTALLER" server
# L'installateur peut réécrire son EnvironmentFile. Restaurer celui créé par le kit
# (proxy, NO_PROXY et éventuelles variables K3S) avant de redémarrer le service.
if [[ -f "$BACKUP_DIR/k3s.service.env-${TARGET_NODE}-${STAMP}" ]]; then
  cp -a "$BACKUP_DIR/k3s.service.env-${TARGET_NODE}-${STAMP}" /etc/systemd/system/k3s.service.env
fi
systemctl daemon-reload
systemctl restart k3s
systemctl is-active --quiet k3s || fail 'Service K3s inactif après mise à niveau. Nœud laissé cordonné.'
k wait --for=condition=Ready "node/$TARGET_NODE" --timeout=900s || fail 'Nœud Kubernetes non Ready après upgrade; laissé cordonné.'
k -n longhorn-system wait --for=condition=Ready "nodes.longhorn.io/$TARGET_NODE" --timeout=900s || fail 'Nœud Longhorn non Ready; laissé cordonné.'
[[ -s /etc/rancher/k3s/config.yaml ]] || fail 'config.yaml K3s absent après mise à niveau.'
# Le post-contrôle gère l'attente Longhorn, l'uncordon, la santé de tout le cluster
# et ne libère le verrou partagé qu'une fois tous les tests passés.
finish_node_maintenance "$TARGET_NODE"
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$STAMP.bak"
set_config_var K3S_VERSION "$TARGET_VERSION"
printf '\nNœud %s mis à niveau avec succès. Procéder au nœud suivant uniquement après un nouveau preflight, une seule cible à la fois.\n' "$TARGET_NODE"
