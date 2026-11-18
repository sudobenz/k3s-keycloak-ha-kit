#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; validate_common; export_proxy_environment
HELM_CURRENT_VERSION=""
if command -v helm >/dev/null 2>&1; then
  HELM_CURRENT_VERSION="$(helm version --template '{{ .Version }}' 2>/dev/null || true)"
fi
if [[ "$HELM_CURRENT_VERSION" != "$HELM_VERSION" ]]; then
  info "Installation de Helm ${HELM_VERSION} (version détectée : ${HELM_CURRENT_VERSION:-absente/invalide})"
  case "$(uname -m)" in
    x86_64) HELM_ARCH="amd64" ;;
    aarch64|arm64) HELM_ARCH="arm64" ;;
    armv7l) HELM_ARCH="arm" ;;
    *) fail "Architecture CPU non prise en charge pour Helm : $(uname -m)" ;;
  esac
  HELM_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$HELM_TMP_DIR"' EXIT
  HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz"
  HELM_CHECKSUM_FILE="${HELM_ARCHIVE}.sha256sum"
  curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}" -o "${HELM_TMP_DIR}/${HELM_ARCHIVE}"
  curl -fsSL "https://get.helm.sh/${HELM_CHECKSUM_FILE}" -o "${HELM_TMP_DIR}/${HELM_CHECKSUM_FILE}"
  HELM_EXPECTED_SHA256="$(awk 'NR == 1 { print $1 }' "${HELM_TMP_DIR}/${HELM_CHECKSUM_FILE}")"
  [[ "$HELM_EXPECTED_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "Somme SHA-256 Helm invalide ou absente."
  printf '%s  %s\n' "$HELM_EXPECTED_SHA256" "$HELM_ARCHIVE" | (cd "$HELM_TMP_DIR" && sha256sum -c -)
  tar -xzf "${HELM_TMP_DIR}/${HELM_ARCHIVE}" -C "$HELM_TMP_DIR"
  install -m 0755 "${HELM_TMP_DIR}/linux-${HELM_ARCH}/helm" /usr/local/bin/helm
  rm -rf "$HELM_TMP_DIR"
  trap - EXIT
  export PATH="/usr/local/bin:$PATH"
  hash -r
fi
command -v helm >/dev/null 2>&1 || fail "Helm n'a pas pu être installé."
[[ "$(helm version --template '{{ .Version }}')" == "$HELM_VERSION" ]] || fail "La version Helm active ne correspond pas à HELM_VERSION=${HELM_VERSION}."

