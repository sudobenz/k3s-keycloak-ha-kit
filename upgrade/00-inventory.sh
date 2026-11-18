#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_upgrade_config; require_cluster
OUT="$REPORT_DIR/inventory-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "K3S / KUBERNETES"; k get nodes -o wide
  echo; echo "HELM RELEASES"; helm list -A
  echo; echo "ALL IMAGES"; k get pods -A -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(p["metadata"]["namespace"],p["metadata"]["name"]," ".join(c["image"] for c in p.get("spec",{}).get("containers",[]))) for p in d.get("items",[])]'
  echo; echo "KUBEVIP"; k -n kube-system get ds kube-vip-ds -o wide
  echo; echo "TRAEFIK"; k -n kube-system get svc traefik -o wide; k -n kube-system get deploy traefik -o wide
  echo; echo "LONGHORN"; helm list -n longhorn-system; k -n longhorn-system get pods -o wide; k -n longhorn-system get nodes.longhorn.io
  echo; echo "CLOUDNATIVEPG"; k get deploy -A | grep cnpg-controller || true; k -n "$(app_namespace)" get cluster "$(cnpg_name)" -o wide; k -n "$(app_namespace)" get pods -l "cnpg.io/cluster=$(cnpg_name)" -o wide
  echo; echo "KEYCLOAK"; k -n "$KEYCLOAK_NAMESPACE" get deploy,keycloak,pods -o wide
  echo; echo "CERT-MANAGER"; helm list -n "$CERT_MANAGER_NAMESPACE"; k -n "$CERT_MANAGER_NAMESPACE" get deploy -o wide || true
  echo; echo "CONFIG PINS"; grep -E '^(K3S_VERSION|KUBEVIP_VERSION|LONGHORN_VERSION|CNPG_VERSION|POSTGRES_IMAGE|KEYCLOAK_VERSION|KEYCLOAK_OPERATOR_REF|CERT_MANAGER_VERSION|HEADLAMP_CHART_VERSION)=' "$CONFIG_FILE" || true
} | tee "$OUT"
printf '\nInventaire enregistré : %s\n' "$OUT"
