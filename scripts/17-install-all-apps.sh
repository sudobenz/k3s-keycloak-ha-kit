#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
[[ -r "$ROOT_DIR/secrets.env" ]] || { echo 'secrets.env absent ; exécuter scripts/00-generate-secrets.sh.' >&2; exit 1; }
for step in \
  03-install-cnpg.sh \
  04-install-cert-manager.sh \
  05-install-keycloak-operator.sh \
  06-deploy-postgres.sh \
  07-prepare-tls-secret.sh \
  08-deploy-keycloak.sh \
  09-create-ingress.sh \
  10-check.sh \
  11-check-ha.sh
 do
  echo "========== ${step} =========="
  bash "${SCRIPT_DIR}/${step}"
done
