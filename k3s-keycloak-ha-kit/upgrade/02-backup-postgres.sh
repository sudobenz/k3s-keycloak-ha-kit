#!/usr/bin/env bash
# Dump logique custom-format du PostgreSQL CNPG en cours. N'écrit aucun secret en argument.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster; require_cmd base64; full_preflight
[[ -r "$ROOT_DIR/secrets.env" ]] || fail "secrets.env absent/illisible; le dump nécessite le secret DB existant."
# shellcheck disable=SC1090
source "$ROOT_DIR/secrets.env"
DB_NS="$KEYCLOAK_NAMESPACE"
DB_NAME="$KEYCLOAK_DB_NAME"
DB_USER="$KEYCLOAK_DB_USER"
DB_PASS="${KEYCLOAK_DB_PASSWORD:-}"
[[ -n "$DB_PASS" ]] || fail 'Secret DB absent dans secrets.env.'
CLUSTER="$(cnpg_name)"
PRIMARY="$(k -n "$DB_NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')"
[[ -n "$PRIMARY" ]] || fail 'Primaire CNPG introuvable.'
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
OUT="$BACKUP_DIR/keycloak-postgresql-$(date +%Y%m%d-%H%M%S).dump"
PASSLINE="*:*:${DB_NAME}:${DB_USER}:${DB_PASS}"
info "Création du dump logique depuis ${PRIMARY}; le mot de passe est transmis sur stdin."
printf '%s\n' "$PASSLINE" | k exec -i -n "$DB_NS" "$PRIMARY" -- sh -c \
  'umask 077; trap "rm -f /tmp/.pgpass-kit-upgrade" EXIT; cat > /tmp/.pgpass-kit-upgrade; PGPASSFILE=/tmp/.pgpass-kit-upgrade pg_dump --format=custom --no-owner --no-acl --username="$1" --dbname="$2"' \
  sh "$DB_USER" "$DB_NAME" > "$OUT"
[[ -s "$OUT" ]] || fail 'Dump vide.'
chmod 600 "$OUT"; sha256sum "$OUT" > "$OUT.sha256"; chmod 600 "$OUT.sha256"
if command -v pg_restore >/dev/null 2>&1; then pg_restore --list "$OUT" >/dev/null || fail 'pg_restore ne reconnaît pas le dump.'; else warn 'pg_restore absent localement : intégrité structurelle non contrôlée; SHA-256 calculé.'; fi
printf '\nDump : %s\nSHA-256 : %s\n' "$OUT" "$(sha256sum "$OUT" | awk '{print $1}')"
printf 'Renseigner ce chemin et son SHA-256 dans upgrade/backup-evidence.env (copie privée à créer depuis le modèle).\n'
