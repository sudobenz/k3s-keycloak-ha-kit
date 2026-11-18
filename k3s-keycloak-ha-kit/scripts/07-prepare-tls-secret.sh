#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_config; validate_common; require_cluster; require_cmd openssl
k create namespace "$KEYCLOAK_NAMESPACE" --dry-run=client -o yaml | k apply -f -
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CERT="$WORK/tls.crt"; KEY="$WORK/tls.key"

case "$KEYCLOAK_TLS_MODE" in
  selfsigned)
    if k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1 && [[ "$TLS_FORCE_REPLACE" != true ]]; then
      warn "Secret existant conservé : ${KEYCLOAK_NAMESPACE}/${KEYCLOAK_TLS_SECRET}. Pour le remplacer, définir TLS_FORCE_REPLACE=true explicitement."
      exit 0
    fi
    SAN="DNS:${KEYCLOAK_FQDN}"
    if [[ -n "${LONGHORN_FQDN:-}" ]]; then SAN="${SAN},DNS:${LONGHORN_FQDN}"; fi
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
      -keyout "$KEY" -out "$CERT" -days "$CERT_VALIDITY_DAYS" \
      -subj "/CN=${KEYCLOAK_FQDN}" \
      -addext "subjectAltName=${SAN}" \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=digitalSignature,keyEncipherment' \
      -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1
    ;;
  files)
    [[ -r "$CERT_FILE" && -r "$KEY_FILE" ]] || fail 'CERT_FILE/KEY_FILE doivent être des fichiers PEM lisibles.'
    CERT="$CERT_FILE"; KEY="$KEY_FILE"
    ;;
  cert-manager)
    k get crd certificates.cert-manager.io >/dev/null || fail 'cert-manager absent : exécuter 04-install-cert-manager.sh.'
    if [[ "$CERT_MANAGER_ISSUER_KIND" == Issuer ]]; then
      k get issuer "$CERT_MANAGER_ISSUER_NAME" -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail "Issuer introuvable : ${KEYCLOAK_NAMESPACE}/${CERT_MANAGER_ISSUER_NAME}"
    else
      k get clusterissuer "$CERT_MANAGER_ISSUER_NAME" >/dev/null || fail "ClusterIssuer introuvable : ${CERT_MANAGER_ISSUER_NAME}"
    fi
    cat > "$WORK/certificate.yaml" <<EOF_CERT
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-public-tls
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  secretName: ${KEYCLOAK_TLS_SECRET}
  dnsNames:
    - ${KEYCLOAK_FQDN}
  duration: ${CERT_MANAGER_CERT_DURATION}
  renewBefore: ${CERT_MANAGER_RENEW_BEFORE}
  privateKey:
    algorithm: RSA
    size: 3072
    rotationPolicy: Always
  issuerRef:
    name: ${CERT_MANAGER_ISSUER_NAME}
    kind: ${CERT_MANAGER_ISSUER_KIND}
    group: cert-manager.io
EOF_CERT
    k apply -f "$WORK/certificate.yaml"
    k wait --for=condition=Ready certificate/keycloak-public-tls -n "$KEYCLOAK_NAMESPACE" --timeout=900s
    k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" >/dev/null || fail 'cert-manager n’a pas créé le Secret TLS.'
    CERT="$WORK/managed.crt"; KEY="$WORK/managed.key"
    k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERT"
    k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d > "$KEY"
    ;;
esac

openssl x509 -in "$CERT" -noout >/dev/null 2>&1 || fail 'Certificat PEM X.509 illisible.'
openssl x509 -in "$CERT" -checkend 0 -noout >/dev/null || fail 'Certificat expiré ou invalide.'
openssl x509 -in "$CERT" -checkhost "$KEYCLOAK_FQDN" -noout >/dev/null || fail "SAN absent pour ${KEYCLOAK_FQDN}."
CERT_HASH="$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
KEY_HASH="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
[[ -n "$CERT_HASH" && "$CERT_HASH" == "$KEY_HASH" ]] || fail 'La clé privée ne correspond pas au certificat.'

if [[ "$KEYCLOAK_TLS_MODE" != cert-manager ]]; then
  if k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1 && [[ "$TLS_FORCE_REPLACE" != true ]]; then
    fail 'Secret TLS déjà existant. Définir TLS_FORCE_REPLACE=true pour autoriser son remplacement.'
  fi
  k create secret tls "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" \
    --cert="$CERT" --key="$KEY" --dry-run=client -o yaml | k apply -f -
fi
printf '\nSecret TLS prêt : %s/%s\n' "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_TLS_SECRET"
openssl x509 -in "$CERT" -noout -subject -issuer -dates -ext subjectAltName
[[ "$KEYCLOAK_TLS_MODE" != selfsigned ]] || warn 'Certificat autosigné de bootstrap uniquement. Remplacer par une chaîne de confiance avant ouverture utilisateurs.'
