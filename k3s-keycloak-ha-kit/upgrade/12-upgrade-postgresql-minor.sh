#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
[[ $# -ge 2 ]] || fail "Usage: $0 <postgresql-image-complete> --apply --backup-evidence <fichier>"
TARGET_IMAGE="$1"; APPLY="$2"; [[ "$APPLY" == --apply || "$APPLY" == --plan ]] || fail 'Utiliser --plan ou --apply.'
EVIDENCE="${4:-}"; [[ "${3:-}" == --backup-evidence && -n "$EVIDENCE" ]] || fail '--backup-evidence obligatoire.'
verify_backup_evidence "$EVIDENCE" yes yes no
CURRENT_IMAGE="$(k -n "$KEYCLOAK_NAMESPACE" get cluster "$CNPG_CLUSTER_NAME" -o jsonpath='{.spec.imageName}')"
[[ -n "$CURRENT_IMAGE" ]] || fail 'Image PostgreSQL courante introuvable.'
python3 - "$CURRENT_IMAGE" "$TARGET_IMAGE" <<'PYIMG'
import re,sys
old,new=sys.argv[1:]
pat=r'^(.*postgresql:)(\d+)\.(\d+)(-.+)?$'
a=re.fullmatch(pat,old); b=re.fullmatch(pat,new)
if not a or not b: raise SystemExit('Images PostgreSQL non reconnues; format attendu: dépôt:MAJOR.MINOR-suffixe.')
if a.group(1)!=b.group(1): raise SystemExit('Le dépôt de l’image doit rester identique.')
if a.group(2)!=b.group(2): raise SystemExit('Mise à niveau majeure PostgreSQL refusée par ce script. Utiliser une migration CNPG majeure dédiée.')
if a.group(4)!=b.group(4): raise SystemExit('Le suffixe de distribution/build doit rester identique.')
if int(b.group(3))<=int(a.group(3)): raise SystemExit('Le numéro de version mineure PostgreSQL doit augmenter; downgrade et version identique refusés.')
PYIMG
full_preflight
printf 'PostgreSQL actuel: %s\nCible: %s\n' "$CURRENT_IMAGE" "$TARGET_IMAGE"
if [[ "$APPLY" == --plan ]]; then echo 'PLAN SEUL : aucune modification.'; exit 0; fi
cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.env.$(date +%Y%m%d-%H%M%S).bak"
k -n "$KEYCLOAK_NAMESPACE" patch cluster "$CNPG_CLUSTER_NAME" --type=merge -p "{\"spec\":{\"imageName\":\"$TARGET_IMAGE\"}}"
wait_cnpg_ready
IMAGES="$(k -n "$KEYCLOAK_NAMESPACE" get pods -l "cnpg.io/cluster=$CNPG_CLUSTER_NAME" -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u)"
[[ "$IMAGES" == "$TARGET_IMAGE" ]] || fail "Les images PostgreSQL ne sont pas toutes sur $TARGET_IMAGE: $IMAGES"
set_config_var POSTGRES_IMAGE "$TARGET_IMAGE"
full_preflight
printf '\nPostgreSQL mis à niveau. Mise à niveau majeure bloquée volontairement.\n'
