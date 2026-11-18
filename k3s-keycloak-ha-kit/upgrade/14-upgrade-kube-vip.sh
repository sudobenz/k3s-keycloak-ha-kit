#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_root; require_cluster
[[ $# -ge 2 ]] || fail "Usage: $0 <KUBEVIP_TARGET_vX.Y.Z> --plan|--apply"
TARGET="${1#v}"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
CURRENT="${KUBEVIP_VERSION#v}"; require_newer_version "$CURRENT" "$TARGET"
full_preflight
MANIFEST=/var/lib/rancher/k3s/server/manifests/kube-vip-ds.yaml
[[ -s "$MANIFEST" ]] || fail "Manifeste Kube-VIP absent: $MANIFEST. Exécuter sur le nœud qui possède le manifeste source."
COUNT="$(grep -Ec '^[[:space:]]*image:[[:space:]]*ghcr\.io/kube-vip/kube-vip:' "$MANIFEST" || true)"
[[ "$COUNT" == 1 ]] || fail "Une seule image ghcr.io/kube-vip/kube-vip attendue dans $MANIFEST (trouvé: $COUNT)."
OLD="$(sed -nE 's/^[[:space:]]*image:[[:space:]]*ghcr.io\/kube-vip\/kube-vip:([^[:space:]]+).*$/\1/p' "$MANIFEST")"
[[ "$OLD" == "$CURRENT" ]] || fail "La version du manifeste ($OLD) diffère du pin config.env ($CURRENT); réconcilier manuellement avant update."
printf 'Kube-VIP: %s -> %s; seul le tag image sera changé, les flags/élections/VIP sont conservés.\n' "$CURRENT" "$TARGET"
if [[ "$APPLY" == --plan ]]; then echo 'PLAN SEUL : aucune modification.'; exit 0; fi
STAMP="$(date +%Y%m%d-%H%M%S)"; cp -a "$MANIFEST" "$BACKUP_DIR/kube-vip-ds.$STAMP.yaml"
sed -i "s#ghcr.io/kube-vip/kube-vip:${CURRENT}#ghcr.io/kube-vip/kube-vip:${TARGET}#" "$MANIFEST"
if ! k apply -f "$MANIFEST"; then cp -a "$BACKUP_DIR/kube-vip-ds.$STAMP.yaml" "$MANIFEST"; k apply -f "$MANIFEST" || true; fail 'Application Kube-VIP en échec; manifeste précédent restauré.'; fi
if ! k -n kube-system rollout status daemonset/kube-vip-ds --timeout=600s; then
  warn 'Rollout Kube-VIP non terminé. Ne pas toucher aux VIP ni aux autres composants; examiner les logs et le leader.'
  fail 'Kube-VIP non Ready après mise à jour. Manifeste précédent disponible dans upgrade/backups.'
fi
assert_ingress_healthy
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$STAMP.bak"
set_config_var KUBEVIP_VERSION "v$TARGET"
printf '\nKube-VIP mis à niveau. Vérifier séparément l’accessibilité de la VIP API et Ingress depuis un poste externe.\n'
