#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; load_secrets; require_cluster; require_cmd sha256sum
mkdir -p "$ROOT_DIR/backups"; chmod 700 "$ROOT_DIR/backups"
PRIMARY="$(k get cluster "$CNPG_CLUSTER_NAME" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.status.currentPrimary}')"
[[ -n "$PRIMARY" ]] || fail 'Primaire PostgreSQL introuvable.'
OUT="$ROOT_DIR/backups/keycloak-${KEYCLOAK_DB_NAME}-$(date +%Y%m%d-%H%M%S).dump"
PASSFILE_LINE="*:*:${KEYCLOAK_DB_NAME}:${KEYCLOAK_DB_USER}:${KEYCLOAK_DB_PASSWORD}"
info "Dump logique en provenance de ${PRIMARY}"
# Le secret est transmis sur stdin puis écrit en fichier temporaire 0600 dans le pod ; il n’est pas dans la ligne de commande pg_dump.
printf '%s\n' "$PASSFILE_LINE" | k exec -i -n "$KEYCLOAK_NAMESPACE" "$PRIMARY" -- sh -c \
  'umask 077; trap "rm -f /tmp/.pgpass-keycloak" EXIT; cat > /tmp/.pgpass-keycloak; PGPASSFILE=/tmp/.pgpass-keycloak pg_dump --format=custom --no-owner --no-acl --username="$1" --dbname="$2"' \
  sh "$KEYCLOAK_DB_USER" "$KEYCLOAK_DB_NAME" > "$OUT"
[[ -s "$OUT" ]] || fail 'Le dump est vide.'
chmod 600 "$OUT"; sha256sum "$OUT" > "${OUT}.sha256"; chmod 600 "${OUT}.sha256"
printf 'Sauvegarde : %s\n' "$OUT"
echo 'Ce dump logique ne remplace pas Barman Cloud/WAL, les sauvegardes etcd K3s et les tests de restauration.'
