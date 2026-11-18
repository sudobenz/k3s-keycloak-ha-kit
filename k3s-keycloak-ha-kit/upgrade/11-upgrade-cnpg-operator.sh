#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ $# -ge 2 ]] || fail "Usage: $0 <CNPG_TARGET_X.Y.Z> --apply --backup-evidence <fichier>"
TARGET="$1"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
EVIDENCE="${4:-}"
[[ "${3:-}" == --backup-evidence && -n "$EVIDENCE" ]] || fail 'Argument --backup-evidence <fichier> obligatoire.'
verify_backup_evidence "$EVIDENCE" yes yes no
CURRENT="${CNPG_VERSION}"
require_same_minor "$CURRENT" "$TARGET"
full_preflight
MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${TARGET%.*}/releases/cnpg-${TARGET}.yaml"
OUT="$UPGRADE_DIR/manifests"; mkdir -p "$OUT"
FILE="$OUT/cnpg-${TARGET}.yaml"
if [[ ! -s "$FILE" ]]; then curl -fsSL "$MANIFEST_URL" -o "$FILE" || fail "Manifeste CNPG indisponible : $MANIFEST_URL"; fi
sha256sum "$FILE" > "$FILE.sha256"
k apply --server-side --dry-run=server -f "$FILE" >/dev/null || fail 'Le dry-run serveur du manifeste CNPG a échoué.'
printf 'Cible CNPG: %s (actuel verrouillé: %s)\nManifeste: %s\nCommande prévue: kubectl apply --server-side -f %q\n' "$TARGET" "$CURRENT" "$FILE" "$FILE"
if [[ "$APPLY" == --plan ]]; then echo 'PLAN SEUL : aucune modification.'; exit 0; fi
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$(date +%Y%m%d-%H%M%S).bak"
k apply --server-side -f "$FILE"
k -n "$CNPG_NAMESPACE" rollout status deployment/cnpg-controller-manager --timeout=900s
wait_cnpg_ready
set_config_var CNPG_VERSION "$TARGET"
full_preflight
printf '\nCloudNativePG mis à niveau vers %s. config.env verrouillé après contrôle.\n' "$TARGET"
