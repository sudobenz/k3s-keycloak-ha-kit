#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OUT="${ROOT_DIR}/secrets.env"
command -v openssl >/dev/null 2>&1 || { echo 'openssl est requis.' >&2; exit 1; }
if [[ -e "$OUT" ]]; then echo "$OUT existe déjà : refus de remplacer les secrets." >&2; exit 1; fi
umask 077
{
  printf 'K3S_TOKEN=%q\n' "$(openssl rand -hex 32)"
  printf 'K3S_JOIN_TOKEN=%q\n' ''
  printf 'KEYCLOAK_DB_PASSWORD=%q\n' "$(openssl rand -hex 32)"
  printf 'LONGHORN_BASIC_AUTH_PASSWORD=%q\n' "$(openssl rand -hex 24)"
} > "$OUT"
chmod 600 "$OUT"
echo 'Secrets générés dans secrets.env (0600). Après bootstrap du nœud 1, le token de jointure sécurisé y sera ajouté.'
echo 'Copier secrets.env uniquement par canal sécurisé ; ne pas le versionner ni le joindre à une archive.'
