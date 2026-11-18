#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root; load_config; validate_common; require_cluster; require_cmd helm
[[ "$HEADLAMP_INSTALL" == true ]] || { echo 'HEADLAMP_INSTALL=false : installation ignorée.'; exit 0; }
PLUGIN_FILE="$ROOT_DIR/config/headlamp-plugins.yml"
[[ -s "$PLUGIN_FILE" ]] || fail "Plugins Headlamp absents : $PLUGIN_FILE"
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update
helm repo update headlamp
helm show chart headlamp/headlamp --version "$HEADLAMP_CHART_VERSION" >/dev/null
k create namespace "$HEADLAMP_NAMESPACE" --dry-run=client -o yaml | k apply -f -
cat > "$ROOT_DIR/output/headlamp-readonly-rbac.yaml" <<EOF_RBAC
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${HEADLAMP_RELEASE}
  namespace: ${HEADLAMP_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${HEADLAMP_RELEASE}-readonly
rules:
  - apiGroups: [""]
    resources: ["namespaces", "nodes", "pods", "pods/log", "services", "endpoints", "events", "persistentvolumes", "persistentvolumeclaims", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "daemonsets", "statefulsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "ingressclasses", "networkpolicies"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csidrivers", "csinodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["postgresql.cnpg.io"]
    resources: ["clusters", "backups", "scheduledbackups", "poolers", "databases", "databaseroles", "publications", "subscriptions", "imagecatalogs", "clusterimagecatalogs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "certificaterequests", "issuers", "clusterissuers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["acme.cert-manager.io"]
    resources: ["orders", "challenges"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${HEADLAMP_RELEASE}-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${HEADLAMP_RELEASE}-readonly
subjects:
  - kind: ServiceAccount
    name: ${HEADLAMP_RELEASE}
    namespace: ${HEADLAMP_NAMESPACE}
EOF_RBAC
k apply -f "$ROOT_DIR/output/headlamp-readonly-rbac.yaml"
helm upgrade --install "$HEADLAMP_RELEASE" headlamp/headlamp \
  --namespace "$HEADLAMP_NAMESPACE" --version "$HEADLAMP_CHART_VERSION" \
  --set service.type=ClusterIP \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$HEADLAMP_RELEASE" \
  --set clusterRoleBinding.create=false \
  --set pluginsManager.enabled=true \
  --set config.watchPlugins=true \
  --set-file pluginsManager.configContent="$PLUGIN_FILE" \
  --wait --timeout=10m
k rollout status "deployment/${HEADLAMP_RELEASE}" -n "$HEADLAMP_NAMESPACE" --timeout=300s
for plugin in cnpg-headlamp-plugin cert-manager; do
  found=false
  for attempt in $(seq 1 100); do
    if k exec -n "$HEADLAMP_NAMESPACE" "deployment/${HEADLAMP_RELEASE}" -c headlamp-plugin -- test -d "/headlamp/plugins/${plugin}" >/dev/null 2>&1; then found=true; break; fi
    sleep 3
  done
  [[ "$found" == true ]] || { k logs -n "$HEADLAMP_NAMESPACE" "deployment/${HEADLAMP_RELEASE}" -c headlamp-plugin --since=20m >&2 || true; fail "Plugin Headlamp non installé : $plugin"; }
done
k -n "$HEADLAMP_NAMESPACE" get svc,pods -o wide
printf '\nHeadlamp installé avec un ClusterRole lecture seule, sans cluster-admin et sans Ingress public. Pour un accès temporaire : kubectl -n %s port-forward svc/%s 8080:80\n' "$HEADLAMP_NAMESPACE" "$HEADLAMP_RELEASE"
