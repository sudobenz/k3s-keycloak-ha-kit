# Diagnostic rapide

Toutes les commandes ci-dessous sont en lecture seule sauf indication contraire. Ne pas activer `bash -x` sur les scripts qui chargent `secrets.env`.

## K3s / etcd

```bash
systemctl status k3s --no-pager
journalctl -u k3s -n 200 --no-pager
k3s kubectl get nodes -o wide
k3s kubectl get --raw=/readyz
k3s etcd-snapshot ls
```

## Kube-VIP / Traefik

```bash
kubectl -n kube-system get pods -o wide | grep -E 'kube-vip|traefik'
kubectl -n kube-system get svc traefik -o yaml
kubectl get helmchartconfig traefik -n kube-system -o yaml
```

Contrôler les conflits ARP, l'interface configurée, la réservation des VIP, le port 443 et les endpoints Ingress.

## Longhorn / PVC

```bash
kubectl -n longhorn-system get pods -o wide
kubectl -n longhorn-system get nodes.longhorn.io -o wide
kubectl -n longhorn-system get volumes.longhorn.io
kubectl get pvc -n keycloak -o wide
kubectl describe pvc -n keycloak <PVC>
```

Pour les volumes PostgreSQL strict-local, ne pas forcer une attache sur un autre nœud et ne pas supprimer un volume/PVC sans connaître l'état de réplication CNPG et la politique de sauvegarde.

## CloudNativePG

```bash
kubectl get cluster keycloak-db -n keycloak -o yaml
kubectl get pods -n keycloak -l cnpg.io/cluster=keycloak-db -o wide
kubectl describe cluster keycloak-db -n keycloak
kubectl logs -n cnpg-system deployment/cnpg-controller-manager --since=30m
```

Vérifier le primaire, les conditions Ready, la réplication, les événements et l'espace disponible. Ne pas promouvoir manuellement une instance sans vérifier les WAL et le quorum.

## Keycloak Operator / serveurs

```bash
kubectl get keycloak keycloak -n keycloak -o yaml
kubectl get pods -n keycloak -o wide
kubectl logs -n keycloak deployment/keycloak-operator --since=30m
kubectl get events -n keycloak --sort-by=.lastTimestamp
```

Le nom de Deployment/selector serveur peut varier selon la version de l'Operator. Lire les labels et les workloads générés avant toute commande sélective.

## Ingress / TLS / OIDC

```bash
kubectl get ingress -n keycloak -o yaml
kubectl describe secret keycloak-tls -n keycloak
curl -vk --resolve keycloak.example.com:443:192.0.2.55 \
  https://keycloak.example.com/realms/master/.well-known/openid-configuration
```

`-k`/`-v` sert au diagnostic uniquement. Ne désactivez pas la validation TLS dans les clients de production. Vérifier les SAN, dates, chaîne complète, Secret de namespace `keycloak`, hostname public et en-têtes proxy.

## AppArmor

```bash
sysctl kernel.apparmor_restrict_unprivileged_unconfined
cat /sys/kernel/security/apparmor/profiles | grep cri-containerd
journalctl -k --since=-30m | grep -i apparmor
```

N'appliquer le script AppArmor fourni que si les journaux confirment le problème de peer empilé décrit dans `APPARMOR-K3S.md`.
