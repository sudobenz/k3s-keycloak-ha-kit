#!/usr/bin/env bash
# Active l'élection Kube-VIP par Service pour préserver l'Ingress Local pendant les drains.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_root; require_cluster
[[ $# -eq 1 ]] || fail "Usage: $0 --plan|--apply"
MODE="$1"; [[ "$MODE" == --plan || "$MODE" == --apply ]] || fail 'Utiliser --plan ou --apply.'
POLICY="$(k -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}')"
[[ "$POLICY" == Local ]] || fail "Traefik externalTrafficPolicy=$POLICY; la procédure attend Local."
assert_ingress_healthy
MANIFEST=/var/lib/rancher/k3s/server/manifests/kube-vip-ds.yaml
[[ -s "$MANIFEST" ]] || fail "Manifeste source absent: $MANIFEST. Exécuter sur le nœud qui le détient."
TMP_MANIFEST="$REPORT_DIR/kube-vip-ds.services-election.yaml"
python3 - "$MANIFEST" "$TMP_MANIFEST" <<'PYEDIT'
from pathlib import Path
import sys,yaml
source=Path(sys.argv[1]); output=Path(sys.argv[2])
data=yaml.safe_load(source.read_text())
if data.get('kind')!='DaemonSet': raise SystemExit('Le manifeste source ne contient pas un DaemonSet.')
cs=data.get('spec',{}).get('template',{}).get('spec',{}).get('containers',[])
if len(cs)!=1: raise SystemExit(f'Nombre inattendu de conteneurs Kube-VIP: {len(cs)}')
args=cs[0].setdefault('args',[])
if not any(a=='--servicesElection' or (a.startswith('--servicesElection=') and a.split('=',1)[1].lower()=='true') for a in args):
    args.append('--servicesElection')
output.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
print('Manifeste cible préparé avec --servicesElection.')
PYEDIT
if ! grep -q -- '--servicesElection' "$TMP_MANIFEST"; then fail 'Le manifeste temporaire ne contient pas --servicesElection.'; fi
if grep -q -- '--servicesElection' "$MANIFEST"; then :; else fail 'Le manifeste modifié ne contient pas --servicesElection.'; fi
printf 'Kube-VIP servicesElection: absent -> présent. La mise à jour conserve l’image, les flags existants et les VIP.\n'
if [[ "$MODE" == --plan ]]; then
  diff -u "$MANIFEST" "$TMP_MANIFEST" || true
  echo 'PLAN SEUL : le manifeste source n’a pas été modifié.'
  exit 0
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
cp -a "$MANIFEST" "$BACKUP_DIR/kube-vip-ds.services-election.$STAMP.yaml"
install -m 0644 "$TMP_MANIFEST" "$MANIFEST"
# Appliquer le manifeste et attendre la fin du rollout.
if ! k apply -f "$MANIFEST"; then
  cp -a "$BACKUP_DIR/kube-vip-ds.services-election.$STAMP.yaml" "$MANIFEST"
  k apply -f "$MANIFEST" || true
  fail 'Application du manifeste Kube-VIP en échec; manifeste précédent restauré.'
fi
if ! k -n kube-system rollout status daemonset/kube-vip-ds --timeout=600s; then
  warn 'Rollout Kube-VIP incomplet. Restauration du manifeste précédent; ne pas redémarrer de nœud.'
  cp -a "$BACKUP_DIR/kube-vip-ds.services-election.$STAMP.yaml" "$MANIFEST"
  k apply -f "$MANIFEST" || true
  k -n kube-system rollout status daemonset/kube-vip-ds --timeout=600s || true
  fail "Kube-VIP non Ready. Manifeste précédent restauré si l'API l'a permis : $BACKUP_DIR/kube-vip-ds.services-election.$STAMP.yaml"
fi
assert_services_election_enabled
assert_ingress_healthy
printf '\nÉlection par Service activée. Vérifier que la VIP 443 reste annoncée par le nœud indiqué dans kube-vip.io/vipHost.\n'
