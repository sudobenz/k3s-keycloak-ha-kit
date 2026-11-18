#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
require_root
load_config
validate_common
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
require_cluster
require_cmd jq
if [[ "$TRAEFIK_ENABLE_HTTP" == true ]]; then WEB_EXPOSE="true"; else WEB_EXPOSE="false"; fi
info "Configuration du Traefik embarqué K3s ; HTTPS VIP ${INGRESS_VIP}:443"
cat <<YAML_EOF | k apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    deployment:
      replicas: 3
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app.kubernetes.io/name: traefik
              topologyKey: kubernetes.io/hostname
    ports:
      web:
        expose:
          default: ${WEB_EXPOSE}
      websecure:
        expose:
          default: true
    service:
      annotations:
        kube-vip.io/loadbalancerIPs: "${INGRESS_VIP}"
      spec:
        externalTrafficPolicy: Local
YAML_EOF
info 'Attente de la réconciliation Traefik'
PORTS_OK=false
for attempt in $(seq 1 120); do
  JSON="$(k -n kube-system get svc traefik -o json 2>/dev/null || true)"
  if [[ -n "$JSON" ]]; then
    if [[ "$TRAEFIK_ENABLE_HTTP" == true ]]; then
      jq -e '.spec.externalTrafficPolicy == "Local" and any(.spec.ports[]?; .port == 443) and any(.spec.ports[]?; .port == 80)' <<<"$JSON" >/dev/null 2>&1 && PORTS_OK=true
    else
      jq -e '.spec.externalTrafficPolicy == "Local" and any(.spec.ports[]?; .port == 443) and all(.spec.ports[]?; .port != 80)' <<<"$JSON" >/dev/null 2>&1 && PORTS_OK=true
    fi
    [[ "$PORTS_OK" == true ]] && break
  fi
  sleep 5
done
[[ "$PORTS_OK" == true ]] || fail 'Traefik n’a pas exposé les ports attendus après 10 minutes.'
k rollout status deployment/traefik -n kube-system --timeout=600s
TRAEFIK_POLICY="$(k -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}')"
[[ "$TRAEFIK_POLICY" == "Local" ]] || fail "Traefik doit conserver externalTrafficPolicy=Local ; valeur actuelle : ${TRAEFIK_POLICY:-absente}."
k -n kube-system get svc traefik -o wide
printf '\nTraefik opérationnel avec externalTrafficPolicy=Local (préservation de l’adresse IP source). HTTP activé=%s ; HTTPS activé=true.\n' "$TRAEFIK_ENABLE_HTTP"
if [[ "$TRAEFIK_ENABLE_HTTP" == false ]]; then echo 'ACME HTTP-01 ne fonctionnera pas : utiliser un challenge DNS-01 ou importer un certificat.'; fi
