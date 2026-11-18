#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
load_config
load_secrets
validate_common
require_cluster
require_cmd openssl
require_cmd htpasswd

LONGHORN_NAMESPACE="longhorn-system"
LONGHORN_SECRET="longhorn-tls"
LONGHORN_AUTH_SECRET="longhorn-basic-auth"
LONGHORN_MIDDLEWARE="longhorn-auth"
LONGHORN_INGRESS="longhorn"

k get svc longhorn-frontend -n "$LONGHORN_NAMESPACE" >/dev/null 2>&1 || fail 'Service longhorn-frontend absent. Longhorn doit être installé.'
k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" >/dev/null 2>&1 || fail "Secret source ${KEYCLOAK_NAMESPACE}/${KEYCLOAK_TLS_SECRET} absent."
k get crd middlewares.traefik.io >/dev/null 2>&1 || fail 'CRD middlewares.traefik.io absente. Traefik CRD provider doit être actif.'
[[ -n "${LONGHORN_FQDN:-}" ]] || fail 'LONGHORN_FQDN absent dans config.env.'
[[ -n "${LONGHORN_BASIC_AUTH_PASSWORD:-}" ]] || fail 'LONGHORN_BASIC_AUTH_PASSWORD absent de secrets.env.'

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/tls.crt"
k get secret "$KEYCLOAK_TLS_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d > "$WORK/tls.key"
chmod 600 "$WORK/tls.crt" "$WORK/tls.key"
openssl x509 -in "$WORK/tls.crt" -checkend 0 -noout >/dev/null || fail 'Certificat TLS source expiré ou invalide.'
openssl x509 -in "$WORK/tls.crt" -checkhost "$LONGHORN_FQDN" -noout >/dev/null || fail "Le certificat TLS ne couvre pas ${LONGHORN_FQDN} dans ses SAN."
CERT_HASH="$(openssl x509 -in "$WORK/tls.crt" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
KEY_HASH="$(openssl pkey -in "$WORK/tls.key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
[[ -n "$CERT_HASH" && "$CERT_HASH" == "$KEY_HASH" ]] || fail 'La clé privée TLS ne correspond pas au certificat.'

info "Synchronisation du Secret TLS vers ${LONGHORN_NAMESPACE}"
k create secret tls "$LONGHORN_SECRET" -n "$LONGHORN_NAMESPACE" \
  --cert="$WORK/tls.crt" --key="$WORK/tls.key" \
  --dry-run=client -o yaml | k apply -f -

info 'Création du Secret BasicAuth'
HTPASSWD_LINE="$(printf '%s\n' "$LONGHORN_BASIC_AUTH_PASSWORD" | htpasswd -niB -C 12 admin)"
k create secret generic "$LONGHORN_AUTH_SECRET" -n "$LONGHORN_NAMESPACE" \
  --from-literal=users="$HTPASSWD_LINE" \
  --dry-run=client -o yaml | k apply -f -
unset HTPASSWD_LINE

mkdir -p "$ROOT_DIR/output"
cat > "$ROOT_DIR/output/longhorn-middleware.yaml" <<EOF_MIDDLEWARE
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${LONGHORN_MIDDLEWARE}
  namespace: ${LONGHORN_NAMESPACE}
spec:
  basicAuth:
    secret: ${LONGHORN_AUTH_SECRET}
    removeHeader: true
EOF_MIDDLEWARE
cat > "$ROOT_DIR/output/longhorn-ingress.yaml" <<EOF_INGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${LONGHORN_INGRESS}
  namespace: ${LONGHORN_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.middlewares: ${LONGHORN_NAMESPACE}-${LONGHORN_MIDDLEWARE}@kubernetescrd
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts:
        - ${LONGHORN_FQDN}
      secretName: ${LONGHORN_SECRET}
  rules:
    - host: ${LONGHORN_FQDN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: longhorn-frontend
                port:
                  number: 80
EOF_INGRESS
k apply -f "$ROOT_DIR/output/longhorn-middleware.yaml"
k apply -f "$ROOT_DIR/output/longhorn-ingress.yaml"
k get middleware "$LONGHORN_MIDDLEWARE" -n "$LONGHORN_NAMESPACE"
k get ingress "$LONGHORN_INGRESS" -n "$LONGHORN_NAMESPACE" -o wide
printf '\nLonghorn disponible sur https://%s avec BasicAuth (utilisateur : admin).\n' "$LONGHORN_FQDN"
printf 'Le mot de passe est dans secrets.env ; ne pas l’afficher dans un journal.\n'
