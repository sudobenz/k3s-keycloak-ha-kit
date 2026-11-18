#!/usr/bin/env bash
# Bibliothèque commune des procédures de mise à niveau. Aucun secret n'est lu ici.
set -Eeuo pipefail
UPGRADE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_APP="keycloak"
ROOT_DIR="$(cd -- "${UPGRADE_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
REPORT_DIR="${UPGRADE_DIR}/reports"
BACKUP_DIR="${UPGRADE_DIR}/backups"
mkdir -p "$REPORT_DIR" "$BACKUP_DIR"

fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf 'AVERTISSEMENT: %s\n' "$*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Commande requise absente : $1"; }

load_upgrade_config() {
  [[ -r "$CONFIG_FILE" ]] || fail "Fichier absent/illisible : $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  require_cmd python3
  require_cmd sha256sum
  if command -v kubectl >/dev/null 2>&1; then KUBECTL=(kubectl)
  elif command -v k3s >/dev/null 2>&1; then KUBECTL=(k3s kubectl)
  else fail 'kubectl ou k3s kubectl requis.'; fi
  require_cmd helm
}
k() { "${KUBECTL[@]}" "$@"; }
require_root() { [[ "$(id -u)" -eq 0 ]] || fail 'Exécuter en root (kubeconfig K3s et manifests locaux requis).'; }

load_kit_proxy_environment() {
  [[ -r "$ROOT_DIR/secrets.env" ]] || return 0
  local exports
  exports="$(bash -c '
    source "$1"
    load_config
    export_proxy_environment
    for n in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
      if [[ -n "${!n:-}" ]]; then printf "export %s=%q\n" "$n" "${!n}"; fi
    done
  ' _ "$ROOT_DIR/scripts/lib.sh")" || fail 'Impossible de charger les paramètres proxy depuis secrets.env.'
  eval "$exports"
}
require_cluster() {
  [[ -r "$KUBECONFIG" ]] || fail "Kubeconfig absent/illisible : $KUBECONFIG"
  k get --raw='/readyz' 2>/dev/null | grep -qx 'ok' || fail 'API Kubernetes /readyz non OK.'
}

# Remplace une seule variable shell simple de config.env de manière atomique.
set_config_var() {
  local name="$1" value="$2"
  python3 - "$CONFIG_FILE" "$name" "$value" <<'PYCFG'
from pathlib import Path
import os,re,sys,tempfile
p=Path(sys.argv[1]); name=sys.argv[2]; value=sys.argv[3]
text=p.read_text()
pattern=re.compile(rf'^{re.escape(name)}=.*$', re.M)
replacement=f'{name}="{value}"'
new,n=pattern.subn(lambda _m: replacement, text)
if n == 0:
    new=text.rstrip()+f'\n{name}="{value}"\n'
elif n != 1:
    raise SystemExit(f'{name}: {n} définitions trouvées dans config.env; refus de modifier.')
fd,tmp=tempfile.mkstemp(prefix='.config.env.',dir=str(p.parent),text=True)
try:
    with os.fdopen(fd,'w') as f: f.write(new); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,p)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PYCFG
}

semver_tuple() {
  python3 - "$1" <<'PYVER'
import re,sys
s=sys.argv[1].lstrip('v')
m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)',s)
if not m: raise SystemExit(f'Version sémantique exacte attendue, reçue : {sys.argv[1]}')
print(' '.join(m.groups()))
PYVER
}
require_newer_version() {
  local current="$1" target="$2"
  python3 - "$current" "$target" <<'PYVER'
import re,sys

def parse(s):
    m=re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)',s)
    if not m: raise SystemExit(f'Format de version invalide : {s}')
    return tuple(map(int,m.groups()))
a,b=map(parse,sys.argv[1:])
if b <= a: raise SystemExit(f'La cible {sys.argv[2]} doit être strictement supérieure à la version actuelle {sys.argv[1]}.')
PYVER
}
require_same_minor() {
  local current="$1" target="$2"
  python3 - "$current" "$target" <<'PYVER'
import re,sys

def parse(s):
    m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)',s.lstrip('v'))
    if not m: raise SystemExit(f'Format de version invalide : {s}')
    return tuple(map(int,m.groups()))
a,b=map(parse,sys.argv[1:])
if a[:2] != b[:2] or b[2] <= a[2]:
    raise SystemExit(f"Cette procédure autorise uniquement les correctifs dans la même branche {a[0]}.{a[1]}; cible {sys.argv[2]} refusée.")
PYVER
}
require_longhorn_path() {
  local current="$1" target="$2"
  python3 - "$current" "$target" <<'PYVER'
import re,sys

def parse(s):
    m=re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)',s)
    if not m: raise SystemExit(f'Format Longhorn invalide : {s}')
    return tuple(map(int,m.groups()))
a,b=map(parse,sys.argv[1:])
if b <= a: raise SystemExit('La version Longhorn cible doit être supérieure à la version installée.')
if a[0] != b[0] or b[1] not in (a[1],a[1]+1):
    raise SystemExit(f'Longhorn : seul un patch ou le minor immédiatement suivant est accepté automatiquement ({a[0]}.{a[1]} -> {b[0]}.{b[1]}). Les sauts et changements majeurs nécessitent une revue manuelle de chaque chemin de mise à niveau.')
PYVER
}

# Le fichier de preuves n'est PAS exécuté comme shell. Format documenté dans backup-evidence.env.example.
verify_backup_evidence() {
  local file="$1" need_etcd="${2:-yes}" need_cnpg="${3:-yes}" need_longhorn="${4:-yes}"
  [[ -r "$file" ]] || fail "Fichier de preuves absent/illisible : $file"
  python3 - "$file" "$need_etcd" "$need_cnpg" "$need_longhorn" <<'PYBACKUP'
from pathlib import Path
import hashlib,re,sys
p=Path(sys.argv[1]); need_etcd,need_cnpg,need_lh=sys.argv[2:]
values={}
for raw in p.read_text().splitlines():
    line=raw.strip()
    if not line or line.startswith('#'): continue
    m=re.fullmatch(r'([A-Z0-9_]+)=(.*)',line)
    if not m: raise SystemExit(f'Ligne invalide dans {p}: {raw!r}')
    values[m.group(1)]=m.group(2).strip().strip('"').strip("'")
if values.get('RESTORE_TESTED','').lower()!='yes':
    raise SystemExit('RESTORE_TESTED=yes obligatoire : la restauration doit avoir été testée, pas seulement une sauvegarde créée.')
for key,needed in [('ETCD_SNAPSHOT_REFERENCE',need_etcd),('CNPG_BACKUP_REFERENCE',need_cnpg),('LONGHORN_BACKUP_REFERENCE',need_longhorn)]:
    if needed=='yes' and (not values.get(key) or 'A_COMPLETER' in values.get(key,'')): raise SystemExit(f'{key} doit référencer une sauvegarde vérifiée, sans marqueur A_COMPLETER.')
if need_cnpg=='yes':
    dump=values.get('CNPG_DUMP_FILE','')
    digest=values.get('CNPG_DUMP_SHA256','')
    if not dump or not digest or 'A_COMPLETER' in dump or 'A_COMPLETER' in digest: raise SystemExit('CNPG_DUMP_FILE et CNPG_DUMP_SHA256 doivent être renseignés.')
    f=Path(dump)
    if not f.is_file(): raise SystemExit(f'Dump PostgreSQL absent : {f}')
    actual=hashlib.sha256(f.read_bytes()).hexdigest()
    if actual.lower()!=digest.lower(): raise SystemExit('SHA-256 du dump PostgreSQL incorrect.')
if not values.get('OPERATOR') or 'A_COMPLETER' in values.get('OPERATOR',''): raise SystemExit('OPERATOR doit identifier la personne qui autorise la maintenance.')
print('Preuves de sauvegarde cohérentes (fichier/digest vérifiés; références et test de restauration attestés par opérateur).')
PYBACKUP
}

configured_nodes() { printf '%s\n' "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME"; }
app_namespace() { printf '%s' "$KEYCLOAK_NAMESPACE"; }
cnpg_name() { printf '%s' "$CNPG_CLUSTER_NAME"; }

assert_nodes_ready() {
  local json="$REPORT_DIR/nodes.json"
  k get nodes -o json > "$json"
  python3 - "$json" "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME" <<'PYNODES'
import json,sys
nodes={n['metadata']['name']:n for n in json.load(open(sys.argv[1])).get('items',[])}
errors=[]
for name in sys.argv[2:]:
    n=nodes.get(name)
    if not n: errors.append(f'{name}: absent'); continue
    ready=next((c.get('status') for c in n.get('status',{}).get('conditions',[]) if c.get('type')=='Ready'),None)
    if ready!='True': errors.append(f'{name}: Ready={ready}')
    if n.get('spec',{}).get('unschedulable',False): errors.append(f'{name}: déjà cordonné')
if errors: raise SystemExit('Nœuds non disponibles :\n - '+'\n - '.join(errors))
PYNODES
}

assert_longhorn_healthy() {
  local nodes_json="$REPORT_DIR/longhorn-nodes.json" vols_json="$REPORT_DIR/longhorn-volumes.json"
  k -n longhorn-system get nodes.longhorn.io -o json > "$nodes_json"
  k -n longhorn-system get volumes.longhorn.io -o json > "$vols_json"
  python3 - "$nodes_json" "$vols_json" "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME" "$(app_namespace)" <<'PYLH'
import json,sys
nodes=json.load(open(sys.argv[1])).get('items',[])
vols=json.load(open(sys.argv[2])).get('items',[])
want=set(sys.argv[3:6]); namespace=sys.argv[6]
found={n['metadata']['name']:n for n in nodes}; errors=[]
for name in want:
    n=found.get(name)
    if not n: errors.append(f'{name}: CR Longhorn absent'); continue
    ready=next((c.get('status') for c in n.get('status',{}).get('conditions',[]) if c.get('type')=='Ready'),None)
    if ready!='True': errors.append(f'{name}: Longhorn Ready={ready}')
strict=[v for v in vols if v.get('status',{}).get('kubernetesStatus',{}).get('namespace')==namespace and v.get('spec',{}).get('dataLocality')=='strict-local']
if len(strict)!=3: errors.append(f'{len(strict)} volumes DB strict-local détectés, attendu 3')
for v in strict:
    name=v.get('metadata',{}).get('name','?'); s=v.get('status',{}); spec=v.get('spec',{})
    if s.get('robustness')!='healthy': errors.append(f'{name}: robustness={s.get("robustness")}')
    if spec.get('numberOfReplicas')!=1: errors.append(f'{name}: numberOfReplicas={spec.get("numberOfReplicas")}')
for v in vols:
    s=v.get('status',{})
    if s.get('state')=='attached' and s.get('robustness') not in ('healthy',None):
        errors.append(f'{v.get("metadata",{}).get("name")}: attached robustness={s.get("robustness")}')
if errors: raise SystemExit('Longhorn dégradé :\n - '+'\n - '.join(errors))
PYLH
}

assert_cnpg_healthy() {
  local ns; ns="$(app_namespace)"; local name; name="$(cnpg_name)"
  local json="$REPORT_DIR/cnpg-cluster.json" pods="$REPORT_DIR/cnpg-pods.json"
  k -n "$ns" get cluster "$name" -o json > "$json"
  k -n "$ns" get pods -l "cnpg.io/cluster=$name" -o json > "$pods"
  python3 - "$json" "$pods" "$NODE1_NAME" "$NODE2_NAME" "$NODE3_NAME" <<'PYCNPG'
import json,sys
c=json.load(open(sys.argv[1])); pods=json.load(open(sys.argv[2])).get('items',[])
errors=[]; status=c.get('status',{})
if not status.get('currentPrimary'): errors.append('currentPrimary absent')
if int(status.get('readyInstances',0))!=3: errors.append(f"readyInstances={status.get('readyInstances')} au lieu de 3")
ready=[]; nodes=set()
for p in pods:
    cs=p.get('status',{}).get('containerStatuses',[])
    if p.get('status',{}).get('phase')=='Running' and cs and all(x.get('ready') for x in cs):
        ready.append(p); nodes.add(p.get('spec',{}).get('nodeName'))
if len(ready)!=3: errors.append(f'{len(ready)} pods PostgreSQL Ready au lieu de 3')
if len(nodes)!=3: errors.append(f'PostgreSQL réparti sur {len(nodes)} nœuds au lieu de 3')
if errors: raise SystemExit('CloudNativePG non sain :\n - '+'\n - '.join(errors))
print('Primaire CNPG :',status.get('currentPrimary'))
PYCNPG
}

assert_ingress_healthy() {
  local policy; policy="$(k -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}' 2>/dev/null || true)"
  [[ "$policy" == Local ]] || fail "Traefik externalTrafficPolicy=$policy (Local obligatoire pour la préservation de l'IP cliente)."
  k -n kube-system rollout status deployment/traefik --timeout=300s >/dev/null
  k -n kube-system rollout status daemonset/kube-vip-ds --timeout=300s >/dev/null
  local pods_json="$REPORT_DIR/traefik-pods.json"
  k -n kube-system get pods -l app.kubernetes.io/name=traefik -o json > "$pods_json"
  python3 - "$pods_json" <<'PYTRAEFIK'
import json,sys
ps=json.load(open(sys.argv[1])).get('items',[]); ready=[]
for p in ps:
    cs=p.get('status',{}).get('containerStatuses',[])
    if p.get('status',{}).get('phase')=='Running' and cs and all(c.get('ready') for c in cs): ready.append(p)
if len(ready)!=3 or len({p.get('spec',{}).get('nodeName') for p in ready})!=3:
    raise SystemExit(f'Traefik doit avoir 3 pods Ready répartis sur 3 nœuds; observé {len(ready)}.')
PYTRAEFIK
  local vip_host; vip_host="$(traefik_vip_host)"
  [[ -n "$vip_host" ]] || fail 'Annotation kube-vip.io/vipHost absente sur le Service Traefik.'
  wait_vip_host_has_local_traefik "$vip_host"
}

assert_app_healthy() {
  k -n "$KEYCLOAK_NAMESPACE" rollout status deployment/keycloak-operator --timeout=600s >/dev/null
  local ready
  ready="$(k -n "$KEYCLOAK_NAMESPACE" get keycloak "$KEYCLOAK_NAME" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
  [[ "$ready" == True ]] || fail "CR Keycloak ${KEYCLOAK_NAME} Ready != True."
  local pods="$REPORT_DIR/keycloak-pods.json"
  k -n "$KEYCLOAK_NAMESPACE" get pods -l app.kubernetes.io/component=server -o json > "$pods"
  python3 - "$pods" "$KEYCLOAK_REPLICAS" <<'PYKC'
import json,sys
ps=json.load(open(sys.argv[1])).get('items',[]); ready=[]
for p in ps:
    cs=p.get('status',{}).get('containerStatuses',[])
    if p.get('status',{}).get('phase')=='Running' and cs and all(c.get('ready') for c in cs): ready.append(p)
want=int(sys.argv[2])
if len(ready)!=want: raise SystemExit(f'{len(ready)} pods Keycloak Ready, attendu {want}.')
if len({p.get('spec',{}).get('nodeName') for p in ready})!=want: raise SystemExit('Les pods Keycloak ne sont pas répartis sur les trois nœuds.')
PYKC
}


# Kube-VIP per-Service election is required before draining/rebooting a node
# while the Traefik Service uses externalTrafficPolicy=Local.
assert_services_election_enabled() {
  local json="$REPORT_DIR/kube-vip-ds.json"
  k -n kube-system get daemonset kube-vip-ds -o json > "$json"
  python3 - "$json" <<'PYSVCELECTION'
import json,sys
obj=json.load(open(sys.argv[1], encoding='utf-8'))
containers=obj.get('spec',{}).get('template',{}).get('spec',{}).get('containers',[])
args=[str(a) for c in containers for a in c.get('args',[])]
found=any(a=='--servicesElection' or a.startswith('--servicesElection=') and a.split('=',1)[1].lower()=='true' for a in args)
if not found:
    raise SystemExit('Kube-VIP DaemonSet ne contient pas --servicesElection. Activer ce mode avec upgrade/09-enable-kube-vip-services-election.sh avant toute maintenance/redémarrage de nœud.')
PYSVCELECTION
}

maintenance_lock_holder() {
  k -n kube-system get lease cluster-maintenance-lock -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true
}

acquire_maintenance_lock() {
  local node="$1" now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat <<EOFLEASE | k -n kube-system create -f - >/dev/null || fail "Un autre cycle de maintenance détient déjà le verrou Kubernetes cluster-maintenance-lock (détenteur: $(maintenance_lock_holder)). Aucun second hôte ne peut être maintenu."
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: cluster-maintenance-lock
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: k3s-ha-kit-upgrade
spec:
  holderIdentity: "$node"
  leaseDurationSeconds: 86400
  acquireTime: "$now"
  renewTime: "$now"
EOFLEASE
  info "Verrou de maintenance cluster détenu par $node."
}

require_maintenance_lock() {
  local node="$1" holder
  holder="$(maintenance_lock_holder)"
  [[ "$holder" == "$node" ]] || fail "Verrou de maintenance détenu par '${holder:-aucun}', pas par '$node'."
}

release_maintenance_lock() {
  local node="$1"
  require_maintenance_lock "$node"
  k -n kube-system delete lease cluster-maintenance-lock
  info "Verrou de maintenance libéré par $node."
}

assert_node_not_cnpg_primary() {
  local node="$1" ns primary primary_node
  ns="$(app_namespace)"
  primary="$(k -n "$ns" get cluster "$(cnpg_name)" -o jsonpath='{.status.currentPrimary}')"
  [[ -n "$primary" ]] || fail 'CNPG ne publie pas de primaire courant; refus de maintenance.'
  primary_node="$(k -n "$ns" get pod "$primary" -o jsonpath='{.spec.nodeName}')"
  [[ -n "$primary_node" ]] || fail "Impossible de résoudre le nœud du primaire CNPG $primary."
  [[ "$primary_node" != "$node" ]] || fail "$node héberge le primaire CNPG $primary. Effectuer un switchover CNPG planifié et vérifié avant maintenance."
}

traefik_vip_host() {
  k -n kube-system get svc traefik -o json | python3 -c 'import json,sys; o=json.load(sys.stdin); print(o.get("metadata",{}).get("annotations",{}).get("kube-vip.io/vipHost", ""))'
}

wait_vip_host_has_local_traefik() {
  local host="$1" json="$REPORT_DIR/traefik-vip-owner-pods.json"
  k -n kube-system get pods -l app.kubernetes.io/name=traefik -o json > "$json"
  python3 - "$json" "$host" <<'PYVIPLOCAL'
import json,sys
items=json.load(open(sys.argv[1], encoding='utf-8')).get('items',[])
host=sys.argv[2]
for p in items:
    cs=p.get('status',{}).get('containerStatuses',[])
    if p.get('spec',{}).get('nodeName')==host and p.get('status',{}).get('phase')=='Running' and cs and all(c.get('ready') for c in cs):
        raise SystemExit(0)
raise SystemExit(f'La VIP Traefik est annoncée par {host}, mais aucun pod Traefik local Ready n’y est observé.')
PYVIPLOCAL
}

wait_vip_moved_from_node() {
  local node="$1" deadline=$((SECONDS+180)) host
  while (( SECONDS < deadline )); do
    host="$(traefik_vip_host)"
    if [[ -n "$host" && "$host" != "$node" ]]; then
      wait_vip_host_has_local_traefik "$host"
      info "VIP Traefik déplacée de $node vers $host; endpoint local Ready confirmé."
      return 0
    fi
    sleep 5
  done
  return 1
}

recover_cancelled_drain() {
  local node="$1" reason="$2" deadline
  warn "$reason Réouverture du nœud $node sans redémarrage, puis contrôle de récupération."
  k uncordon "$node" >/dev/null 2>&1 || true
  deadline=$((SECONDS+900))
  while (( SECONDS < deadline )); do
    if full_preflight > "$REPORT_DIR/maintenance-recovery.log" 2>&1; then
      release_maintenance_lock "$node"
      fail "$reason La maintenance est annulée; le cluster est revenu à l'état sain."
    fi
    sleep 15
  done
  cat "$REPORT_DIR/maintenance-recovery.log" >&2 || true
  fail "$reason La récupération automatique n'a pas été confirmée. Le verrou reste en place; ne pas redémarrer le nœud ni maintenir un autre hôte."
}

prepare_node_for_maintenance() {
  local node="$1"
  full_preflight
  assert_services_election_enabled
  assert_node_not_cnpg_primary "$node"
  acquire_maintenance_lock "$node"
  if ! k cordon "$node"; then
    release_maintenance_lock "$node"
    fail "Impossible de cordonner $node."
  fi
  if ! k drain "$node" --ignore-daemonsets --delete-emptydir-data --pod-selector='!cnpg.io/cluster' --timeout=10m; then
    recover_cancelled_drain "$node" "Drain de $node bloqué (PDB/volume/pod non évictable)."
  fi
  if ! wait_vip_moved_from_node "$node"; then
    recover_cancelled_drain "$node" "La VIP Traefik n'a pas quitté $node dans le délai de 180 secondes."
  fi
  info "$node est cordonné et drainé; CNPG strict-local est resté en place; VIP Traefik confirmée sur un autre nœud. La maintenance OS/K3s peut commencer."
}

finish_node_maintenance() {
  local node="$1" deadline
  require_maintenance_lock "$node"
  [[ "$(hostname -s)" == "$node" ]] || fail "À lancer localement sur $node après son redémarrage (hostname actuel: $(hostname -s))."
  require_cmd systemctl
  systemctl is-active --quiet k3s || fail 'Service k3s inactif après retour de l’hôte; conserver le verrou et diagnostiquer.'
  systemctl is-active --quiet iscsid || fail 'Service iscsid inactif; ne pas réintégrer l’hôte Longhorn.'
  if [[ "${LONGHORN_REQUIRE_MOUNT:-false}" == true ]]; then
    mountpoint -q "$LONGHORN_DATA_PATH" || fail "Montage Longhorn absent sur $LONGHORN_DATA_PATH; conserver le verrou et ne pas uncordon."
  fi
  k wait --for=condition=Ready "node/$node" --timeout=900s || fail "$node n'est pas Ready; conserver le verrou et ne pas passer à un autre hôte."
  k -n longhorn-system wait --for=condition=Ready "nodes.longhorn.io/$node" --timeout=900s || fail "Longhorn ne considère pas $node Ready; conserver le verrou."
  k uncordon "$node"
  deadline=$((SECONDS+2400))
  while (( SECONDS < deadline )); do
    if full_preflight > "$REPORT_DIR/maintenance-postcheck.log" 2>&1; then
      if "$ROOT_DIR/scripts/10-check.sh" >> "$REPORT_DIR/maintenance-postcheck.log" 2>&1 && "$ROOT_DIR/scripts/11-check-ha.sh" >> "$REPORT_DIR/maintenance-postcheck.log" 2>&1; then
        release_maintenance_lock "$node"
        cat "$REPORT_DIR/maintenance-postcheck.log"
        printf '\nMaintenance terminée : %s réintégré; trois nœuds, Longhorn, CNPG, Traefik et Keycloak sont sains.\n' "$node"
        return 0
      fi
    fi
    sleep 15
  done
  cat "$REPORT_DIR/maintenance-postcheck.log" >&2 || true
  k cordon "$node" >/dev/null 2>&1 || true
  fail "Le post-contrôle n'est pas revenu au vert après 40 minutes. $node a été re-cordonné si possible; le verrou cluster-maintenance-lock est conservé. Ne pas lancer d'autre maintenance."
}

full_preflight() {
  require_cluster
  info 'Contrôle des trois nœuds Kubernetes'
  assert_nodes_ready
  info 'Contrôle de l’Ingress et de Kube-VIP'
  assert_ingress_healthy
  info 'Contrôle Longhorn et des volumes strict-local'
  assert_longhorn_healthy
  info 'Contrôle CloudNativePG / PostgreSQL'
  assert_cnpg_healthy
  info 'Contrôle applicatif'
  assert_app_healthy
  info 'Pré-contrôle terminé : aucun état dégradé détecté.'
}

print_apply_required() { [[ "${1:-}" == --apply ]] || fail 'Aucune modification effectuée. Pour appliquer après revue, ajouter explicitement --apply.'; }

chart_version() {
  local release="$1" ns="$2"
  helm list -n "$ns" --filter "^${release}$" -o json | python3 -c 'import json,sys; x=json.load(sys.stdin); print(x[0]["chart"].rsplit("-",1)[-1] if x else "")'
}

wait_cnpg_ready() {
  local ns; ns="$(app_namespace)"; local name; name="$(cnpg_name)"
  local deadline=$((SECONDS+3600))
  while (( SECONDS < deadline )); do
    local ready
    ready="$(k -n "$ns" get cluster "$name" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)"
    if [[ "$ready" == 3 ]]; then
      local all
      all="$(k -n "$ns" get pods -l "cnpg.io/cluster=$name" -o jsonpath='{range .items[*]}{.status.phase}{" "}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' 2>/dev/null || true)"
      if [[ -n "$all" ]] && ! grep -Eqi 'Pending|CrashLoop|False' <<<"$all"; then
        assert_cnpg_healthy
        return 0
      fi
    fi
    sleep 10
  done
  fail 'CloudNativePG n’est pas revenu à 3 instances Ready sous 60 minutes. Arrêter les autres mises à jour et diagnostiquer.'
}
