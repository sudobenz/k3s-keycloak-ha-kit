# Kit autonome K3s HA + Keycloak

**Version du kit : 1.2.2 – révision de séparation applicative et de préparation à la publication**  
**Périmètre : installation indépendante depuis des hôtes vierges jusqu'à une plateforme Keycloak HA.**

Ce kit ne dépend d'aucun autre kit applicatif ni d'un cluster Kubernetes déjà installé. Il installe son propre cluster K3s à trois nœuds, le plan de contrôle etcd, Kube-VIP, Traefik, Longhorn, CloudNativePG, cert-manager, l'Operator officiel Keycloak, PostgreSQL et Keycloak.

Les paramètres IP/FQDN ci-dessous sont des valeurs de documentation réservées aux exemples. Ils doivent être remplacés par les valeurs de l’environnement cible. Aucun secret, kubeconfig, certificat privé, keytab ou mot de passe réel n’est livré dans l’archive.

> **Mode de fonctionnement :** bootstrap initial sur trois machines vierges. Les scripts d'installation K3s, de partitionnement et de formatage Longhorn sont destructifs ou non réentrants. Ne pas les exécuter sur un cluster déjà en production.

## 1. Architecture cible

| Composant | Version / paramètre | Rôle |
|---|---|---|
| OS | Ubuntu Server 26.04 LTS (cible principale) | Trois VM/serveurs dédiés |
| Nœuds | `k3s-1` (`192.0.2.51`), `k3s-2` (`192.0.2.52`), `k3s-3` (`192.0.2.53`) | Trois serveurs K3s / etcd embarqué |
| K3s | `v1.36.6+k3s1` | Kubernetes HA avec datastore etcd embarqué |
| VIP API | `192.0.2.54:6443` | Point d'accès API Kubernetes |
| VIP Ingress | `192.0.2.55` | Service LoadBalancer Traefik |
| Kube-VIP | `v1.3.1` | VIP API et VIP de service |
| Helm | `v4.3.1` | Gestion des charts |
| Traefik | Chart K3s embarqué, 3 replicas répartis sur les 3 nœuds, `externalTrafficPolicy: Local` | Ingress HTTPS avec préservation de l’IP source |
| Longhorn | `1.13.0` | Stockage distribué |
| CloudNativePG | Operator `1.30.1` | Gestion PostgreSQL |
| PostgreSQL | `18.6-system-trixie` | Base de données dédiée Keycloak |
| cert-manager | `v1.21.3` | Émission/renouvellement optionnel TLS |
| Keycloak | `26.8.2` + Operator officiel `26.8.2` | IAM / OIDC / SAML / LDAP / Kerberos |
| Keycloak Operator | 1 replica de contrôleur | Réconciliation des ressources Keycloak |
| Serveurs Keycloak | 3 instances | Service IAM distribué |
| PostgreSQL CNPG | 3 instances | Base HA avec réplication native |
| Ingress | `keycloak.example.com` | TLS terminé par Traefik |

### Répartition souhaitée

- Les trois serveurs K3s hébergent etcd et le plan de contrôle.
- Les trois pods Keycloak sont répartis par contrainte de topologie sur trois hôtes distincts.
- Les trois instances PostgreSQL CNPG sont réparties sur trois hôtes distincts.
- Chaque instance PostgreSQL a son propre PVC Longhorn strict-local ; la réplication entre bases est assurée par PostgreSQL/CNPG, pas par réplication Longhorn du même PVC.
- Traefik est déployé en trois replicas avec anti-affinité.
- L'Operator Keycloak reste normalement à un replica : il s'agit du contrôleur de gestion et non du serveur qui traite les requêtes utilisateur.

## 2. Versions et réserves de compatibilité

Les versions sont épinglées dans `config.env.example` comme base de reproduction pour cette révision : K3s `v1.36.6+k3s1`, Longhorn `1.13.0`, CloudNativePG `1.30.1`, cert-manager `v1.21.3` et Keycloak/Operator `26.8.2`.

**Réserve Keycloak/K3s :** la documentation Keycloak indique que les distributions Kubernetes hors OpenShift sont prises en charge au mieux (« best effort »). La matrice de versions testées publiée ne certifie pas explicitement K3s/Kubernetes 1.36. Ce kit fixe les versions mais ne transforme pas cette combinaison en matrice officiellement certifiée par Keycloak. Il faut la qualifier sur un environnement de préproduction avant mise en production.

Longhorn 1.13 requiert Kubernetes 1.34 ou supérieur. CloudNativePG 1.30.1 annonce la compatibilité Kubernetes 1.36. cert-manager 1.21.3 est sélectionné pour cette génération Kubernetes.

## 3. Prérequis matériels et réseau

### Hôtes

Prévoir trois hôtes/VM indépendants, avec :

- Ubuntu Server 26.04 LTS, systemd, noyau avec AppArmor et modules de stockage requis ;
- 4 vCPU et 8 Gio RAM minimum par nœud comme point de départ de laboratoire ; augmenter selon le débit IAM, le nombre d'utilisateurs et les caches ;
- une interface réseau stable (par défaut `ens18`) avec une IPv4 statique ;
- un disque système et un disque de données indépendant par nœud pour Longhorn ;
- synchronisation horaire NTP et résolution DNS cohérente ;
- connectivité sortante HTTPS vers les dépôts Ubuntu, Helm, GitHub, GHCR et Quay.

Les ressources Keycloak par défaut demandent 500m CPU / 1700Mi mémoire par pod, avec limites 2 CPU / 2Gi. PostgreSQL demande 1 CPU / 1Gi par instance. Ces valeurs sont un point de départ et doivent être validées par charge réelle.

### Adresses de documentation (à remplacer)

| Nœud | Adresse |
|---|---|
| `k3s-1` | `192.0.2.51` |
| `k3s-2` | `192.0.2.52` |
| `k3s-3` | `192.0.2.53` |
| VIP API | `192.0.2.54` |
| VIP Traefik | `192.0.2.55` |

Le réseau des nœuds doit être un même segment L2 pour le mode ARP de Kube-VIP. Les deux VIP doivent être réservées et exclues du DHCP. Vérifier que l’interface `ens18` est correcte sur les trois hôtes. Les IP `192.0.2.0/24` sont réservées à la documentation (TEST-NET-1) et ne sont pas routables.

### DNS

Créer au minimum :

```text
keycloak.example.com  A  192.0.2.55
```

Le FQDN Longhorn `longhorn.example.com` est optionnel et sert uniquement si l'Ingress Longhorn protégé par BasicAuth est activé.

## 4. Contenu du kit

```text
k3s-keycloak-ha-kit/
├── config.env.example          # modèle public ; copier vers config.env avant usage
├── secrets.env.example         # modèle uniquement ; ne pas utiliser comme secret réel
├── scripts/                    # bootstrap, déploiement, contrôles et maintenance
├── manifests/                  # StorageClasses et exemples cert-manager
├── config/                     # plugins Headlamp optionnels
├── docs/                       # LDAP/AD, Kerberos, TLS, sécurité, réseau, sauvegardes
├── portainer/                  # intégration Edge Agent et gestion des manifests
├── backups/                    # répertoire de sauvegarde local (vide)
├── output/                     # manifests générés et diagnostics (vide)
└── prometheus-values.example.yaml
```

## 5. Préparer les fichiers

Extraire l'archive sur un poste d'administration ou sur `k3s-1`, puis copier le répertoire complet sur chacun des trois nœuds. Les commandes ci-dessous supposent que le répertoire s'appelle `/opt/k3s-keycloak-ha-kit` ; adapter si besoin.

```bash
cd /opt/k3s-keycloak-ha-kit
chmod 700 scripts/*.sh
chmod 700 scripts/*.py 2>/dev/null || true
```

Créer d’abord la configuration locale, puis l’éditer avant toute opération :

```bash
cp config.env.example config.env
chmod 600 config.env
```

`config.env` est volontairement ignoré par Git. Vérifier en particulier :

- `NODE*_NAME`, `NODE*_IP`, `KUBEVIP_INTERFACE` ;
- `K3S_API_VIP`, `INGRESS_VIP`, `K3S_POD_CIDR`, `K3S_SERVICE_CIDR` ;
- `KEYCLOAK_FQDN`, `LONGHORN_FQDN` ;
- versions K3s, Longhorn, CNPG, PostgreSQL, cert-manager, Keycloak ;
- `PG_STORAGE_SIZE`, `PG_SYNC_MODE`, ressources CPU/mémoire ;
- `KEYCLOAK_TLS_MODE` et les chemins de certificats le cas échéant ;
- proxy d'entreprise et CA si nécessaires.

Ne pas placer de mot de passe, token ou clé privée dans `config.env`.

## 6. Préparer les disques Longhorn

Effectuer cette étape sur **chacun des trois nœuds**, avec un disque de données dédié. Identifier le bon périphérique avec `lsblk` et `/dev/disk/by-id/`. Le script exige un `--disk-id` explicite et une confirmation interactive `FORMAT-LONGHORN`.

```bash
sudo apt-get update && sudo apt-get install -y parted e2fsprogs
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
sudo bash scripts/prepare-longhorn-disk.sh \
  --disk-id /dev/disk/by-id/<IDENTIFIANT_DISQUE>
```

Cette opération partitionne et formate le disque sélectionné en GPT/ext4, ajoute une entrée `/etc/fstab` et monte le volume sur `/var/lib/longhorn`. **Toutes les données du disque sélectionné seront détruites.** Ne jamais choisir le disque système. Répéter sur les trois hôtes et vérifier `findmnt /var/lib/longhorn`.

En cas d'extension ultérieure d'un disque virtuel, `scripts/extend-longhorn-disk.sh` fonctionne en mode simulation par défaut. Utiliser `--apply` uniquement après inspection de la cible et sauvegarde appropriée.

## 7. Générer et distribuer les secrets

Sur `k3s-1` uniquement, après avoir copié `config.env` :

```bash
cd /opt/k3s-keycloak-ha-kit
bash scripts/00-generate-secrets.sh
chmod 600 secrets.env
```

Le script génère le token initial K3s, le mot de passe PostgreSQL Keycloak et le mot de passe BasicAuth Longhorn. Il refuse d'écraser un fichier existant.

Copier `config.env` et `secrets.env` sur les nœuds 2 et 3 via un canal sécurisé. Garder `secrets.env` en mode `0600`. Après l'installation du nœud 1, le script ajoute au fichier `secrets.env` le token sécurisé de jointure K3s ; recopier alors la version mise à jour vers les nœuds 2 et 3 avant leur bootstrap.

Ne jamais activer `set -x` ou `bash -x` sur un script qui charge `secrets.env`. Les journaux de debug pourraient révéler les tokens et mots de passe.

## 8. Préflight et installation K3s HA

Sur chaque hôte, vérifier que `config.env` et `secrets.env` sont présents et que le nom d'hôte correspond au `NODE*_NAME` configuré. Exécuter le préflight local avec l'index du nœud :

```bash
# sur k3s-1
sudo bash scripts/01-preflight-host.sh 1
# sur k3s-2
sudo bash scripts/01-preflight-host.sh 2
# sur k3s-3
sudo bash scripts/01-preflight-host.sh 3
```

Sur `k3s-1` :

```bash
sudo bash scripts/01-install-k3s-node.sh 1
```

Récupérer la version mise à jour de `secrets.env` depuis `k3s-1`, la copier de façon sécurisée sur `k3s-2` et `k3s-3`, puis exécuter :

```bash
# sur k3s-2
sudo bash scripts/01-install-k3s-node.sh 2
# sur k3s-3
sudo bash scripts/01-install-k3s-node.sh 3
```

Depuis `k3s-1`, contrôler :

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get --raw=/readyz
```

Les trois nœuds doivent être `Ready` et le endpoint `/readyz` doit retourner `ok`. Le script ne réinstalle pas un K3s existant : s'il détecte une installation précédente, il s'arrête.

## 9. Installer le réseau, le stockage et l'Ingress

Toutes les étapes suivantes se font depuis `k3s-1` en root (ou via un compte autorisé) :

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
bash scripts/02-install-vips.sh
bash scripts/02a-install-longhorn.sh
bash scripts/02b-configure-ingress.sh
```

- `02-install-vips.sh` installe kube-vip pour la VIP API et affecte la VIP Ingress au Service Traefik. Le manifeste RBAC kube-vip est récupéré depuis le site officiel pendant l’installation ; il doit être revu/vendored pour une chaîne de livraison strictement hermétique (voir `docs/SECURITY.md`).
- `02a-install-longhorn.sh` installe Helm si nécessaire, déploie Longhorn et crée les StorageClasses du kit.
- `02b-configure-ingress.sh` configure le Traefik K3s embarqué, trois replicas répartis par anti-affinité, la VIP Ingress et `service.spec.externalTrafficPolicy: Local` pour préserver l’adresse IP source du client. Par défaut, seul HTTPS/443 est exposé ; HTTP/80 est désactivé.

Contrôler :

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl -n kube-system get svc traefik -o wide
kubectl -n longhorn-system get pods -o wide
kubectl get storageclass
```

Les trois nœuds doivent posséder un Longhorn Node Ready et un disque planifiable. Le stockage de PostgreSQL est configuré sur `longhorn-pg-local` : `numberOfReplicas=1` et `dataLocality=strict-local`. La résilience DB vient des trois PVC/instances PostgreSQL séparés et de la réplication CNPG, et non d'un doublement des réplicas Longhorn pour chaque volume.

## 10. Déployer CloudNativePG, cert-manager et Keycloak

Les prérequis réseau/stockage étant opérationnels, exécuter :

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
bash scripts/03-install-cnpg.sh
bash scripts/04-install-cert-manager.sh
bash scripts/05-install-keycloak-operator.sh
bash scripts/06-deploy-postgres.sh
bash scripts/07-prepare-tls-secret.sh
bash scripts/08-deploy-keycloak.sh
bash scripts/09-create-ingress.sh
```

Ou utiliser l'orchestrateur des applications (il ne bootstrappe pas K3s, Kube-VIP, Longhorn ou Traefik) :

```bash
bash scripts/17-install-all-apps.sh
```

### Rôle de chaque composant

- **CloudNativePG Operator :** un contrôleur dans `cnpg-system`, qui gère la ressource PostgreSQL `keycloak-db` dans le namespace `keycloak`.
- **PostgreSQL :** trois instances séparées, StorageClass strict-local, réplication PostgreSQL synchrone `preferred` par défaut avec failover quorum activé.
- **cert-manager :** installé indépendamment, pour l'émission et le renouvellement lorsqu'un Issuer/ClusterIssuer est configuré.
- **Keycloak Operator :** un replica dans `keycloak`, il réconcilie la ressource `Keycloak`.
- **Keycloak Server :** trois instances, contrainte de répartition `DoNotSchedule` sur les noms de nœuds.
- **Traefik :** reçoit HTTPS sur la VIP Ingress, termine TLS avec le Secret `keycloak-tls` et relaie HTTP au Service `keycloak-service:8080`.

### Choisir le mode TLS

Trois modes sont disponibles dans `config.env` :

1. `KEYCLOAK_TLS_MODE="selfsigned"` : génère un certificat autosigné pour bootstrap/qualification. Les navigateurs ne lui feront pas confiance ; ne pas l'utiliser pour des utilisateurs de production.
2. `KEYCLOAK_TLS_MODE="files"` : importe `CERT_FILE` (fullchain PEM) et `KEY_FILE` (clé privée PEM) dans le Secret Kubernetes `keycloak-tls`. Le SAN doit couvrir `KEYCLOAK_FQDN`.
3. `KEYCLOAK_TLS_MODE="cert-manager"` : nécessite que cert-manager soit installé et qu'un `Issuer` ou `ClusterIssuer` fonctionnel existe déjà. Renseigner le nom et le type de l'Issuer avant de lancer le script TLS.

Le kit ne devine pas la configuration DNS d'un fournisseur ACME. Un exemple Cloudflare DNS-01 est fourni dans `manifests/clusterissuer-cloudflare-dns01.example.yaml` ; remplacer les placeholders, créer le Secret de token dans `cert-manager`, puis appliquer le ClusterIssuer. Si le port 80 est fermé, utiliser DNS-01 ; HTTP-01 ne fonctionnera pas.

Un Secret TLS créé manuellement par Portainer dans le namespace `keycloak` peut également être utilisé : nom `keycloak-tls`, type `kubernetes.io/tls`, clés `tls.crt` et `tls.key`. Dans ce cas, ne pas exécuter l'étape de génération/import TLS automatisée si elle risquerait de remplacer le Secret existant.

## 11. Premier démarrage Keycloak

L'Operator génère un Secret `keycloak-initial-admin` dans le namespace `keycloak`. Récupérer le username/password localement sur une session d'administration protégée :

```bash
kubectl get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Ne pas coller ce secret dans un ticket ou une conversation. Changer immédiatement le mot de passe bootstrap, créer des comptes nominatifs, activer MFA pour les administrateurs et définir un compte break-glass dont les identifiants sont conservés dans un coffre.

URL de découverte OIDC attendue :

```text
https://keycloak.example.com/realms/master/.well-known/openid-configuration
```

## 12. Contrôles et haute disponibilité

```bash
bash scripts/10-check.sh
bash scripts/11-check-ha.sh
bash scripts/16-check-platform.sh
```

Le contrôle HA doit montrer : 3 pods Keycloak Running sur 3 nœuds, 3 pods PostgreSQL Running sur 3 nœuds et un Operator Keycloak disponible. Le script observe le placement, il ne provoque pas de panne et ne mesure pas le RTO/RPO.

**Operator Keycloak à un replica :** cela ne réduit pas le nombre de serveurs Keycloak. En cas d'indisponibilité temporaire de l'Operator, les instances déjà lancées continuent normalement de répondre ; la réconciliation des changements est suspendue jusqu'au retour du contrôleur.

## 13. Intégration Active Directory et Kerberos

La fédération LDAP/LDAPS et l'authentification intégrée Kerberos/SPNEGO ne sont pas activées automatiquement : elles dépendent du domaine AD, des contrôleurs, DN, comptes de service, CA LDAPS, SPN et keytab réels.

- `docs/ACTIVE-DIRECTORY-LDAP.md` : fédération AD, mappers, LDAPS, validation.
- `docs/KERBEROS-SPNEGO.md` : SPN HTTP, keytab, navigateur Windows, flux Browser.

Ne pas intégrer un keytab à l'archive. Le montage proposé via `unsupported.podTemplate` doit être évalué avec la version précise de l'Operator et n'est pas activé par défaut.

## 14. Exploitation, Portainer et Headlamp (options)

### Headlamp

Headlamp est optionnel. Pour l'installer, passer `HEADLAMP_INSTALL="true"` dans `config.env`, puis exécuter :

```bash
bash scripts/13-install-headlamp.sh
```

Le script ajoute les plugins CNPG et cert-manager, avec un ClusterRole lecture seule, sans `cluster-admin`, et ne crée pas d'Ingress public. Accès temporaire par port-forward :

```bash
kubectl -n headlamp port-forward svc/my-headlamp 8080:80
```

La configuration d'un SSO OIDC et du RBAC individualisé doit être réalisée et qualifiée séparément avant exposition aux utilisateurs.

### Portainer

Voir `portainer/README.md`. Le kit n'installe pas le serveur Portainer. Le script `15-integrate-portainer.sh` applique uniquement un manifeste Kubernetes Edge Agent généré depuis l'instance Portainer réelle. Il ne fabrique pas de token ou d'URL d'Edge Agent.

### Ingress Longhorn optionnel

Le script `14-configure-longhorn-ingress.sh` expose l'interface Longhorn sur `LONGHORN_FQDN`, avec BasicAuth. Il nécessite un certificat dont les SAN couvrent aussi `LONGHORN_FQDN`, ainsi que les CRD Middleware de Traefik. En mode certificat PEM, un certificat contenant uniquement `KEYCLOAK_FQDN` ne suffira pas.

## 15. Sauvegarde et restauration

Un dump logique ponctuel est fourni :

```bash
bash scripts/12-backup-db.sh
```

Le fichier `.dump` et son checksum SHA-256 sont placés dans `backups/`, avec permissions restrictives. Copier immédiatement les artefacts vers un stockage externe chiffré. Cette sauvegarde logique ne remplace pas Barman Cloud/WAL ni les snapshots etcd K3s.

Pour une production, configurer un `ObjectStore` Barman Cloud CNPG avec un endpoint S3 compatible, les identifiants placés dans un Secret, la rétention et l'archivage WAL. Les paramètres du fournisseur de stockage n'ayant pas été fournis, le kit ne crée pas de bucket/credentials fictifs. Voir `docs/BACKUP-RESTORE.md`.

## 16. Protection des hôtes et maintenance

Le complément détaillé est dans `docs/HOST-SECURITY-MAINTENANCE.md`.

Sur chacun des trois hôtes, renseigner les IP/CIDR d'administration dans `FAIL2BAN_IGNORE_IPS` de `config.env`, puis exécuter :

```bash
sudo bash scripts/configure-host-protection.sh
sudo bash scripts/check-host-protection.sh
```

Cela active Fail2ban uniquement pour SSH et désactive l'installation autonome APT ainsi que les redémarrages automatiques non coordonnés. Ne pas activer UFW ou un jeu de règles nftables générique sur les nœuds.

Les scripts de maintenance PatchMon sont :

```bash
sudo bash scripts/patchmon-precheck.sh k3s-2
# puis cordon/drain selon les commandes affichées, PatchMon sur ce seul hôte
sudo bash scripts/patchmon-postcheck.sh k3s-2
```

Le pré-contrôle bloque si le cluster est dégradé ou si le nœud cible héberge le primaire PostgreSQL. Le drain exclut explicitement les pods CNPG strict-local. Le post-contrôle attend aussi que le nœud Longhorn soit Ready avant de faire `uncordon`. Ne maintenir qu'un seul nœud à la fois. Ces scripts n'exécutent pas eux-mêmes la mise à jour OS.

**Important :** ne pas appliquer de politique PatchMon `patch_all` simultanément au groupe des trois nœuds et ne pas activer `unattended-upgrades`/reboot locaux. PatchMon ne fournit pas, dans cette configuration, une orchestration cluster-aware avec blocage automatique sur la santé K3s/CNPG/Longhorn. L'autonomie complète nécessite un orchestrateur externe séquentiel; voir les limites et la procédure sûre dans `docs/HOST-SECURITY-MAINTENANCE.md`.

Autres scripts :

- `scripts/fix-k3s-apparmor-stacked-peer.sh` : correctif AppArmor conditionnel ; uniquement si le diagnostic AppArmor confirme le problème. La qualification historique porte sur K3s 1.36.5 / containerd 2.3.4 ; le kit épingle 1.36.6. Voir `docs/APPARMOR-K3S.md`.
- `scripts/pgbench-isolated.sh RUN-ISOLATED-BENCHMARK` : benchmark explicitement opt-in, dans une base jetable distincte.
- `scripts/http-benchmark.py` : test HTTP/endpoint OIDC, pas un test de charge exhaustive.

## 17. Sécurité et limites

- `secrets.env`, kubeconfig, CA privées, fichiers PEM/PFX/JKS et keytabs sont exclus du kit et du dépôt.
- Ne jamais afficher les secrets dans des logs ou utiliser le mode trace Bash sur les scripts qui chargent ces valeurs.
- Le Secret `keycloak-db-credentials` contient les identifiants de la base ; protéger l'accès au namespace `keycloak`.
- Le CR Keycloak et les Secrets associés doivent être réservés aux administrateurs de confiance.
- Le CR Keycloak restreint `networkPolicy.http` au namespace `kube-system` pour limiter l'accès au frontal Traefik. Cette fonction NetworkPolicy de l'Operator est Preview ; vérifier le CNI, les labels/namespace et les probes en préproduction. La confiance dans `X-Forwarded-*` exige que les requêtes publiques passent par Traefik et que celui-ci écrase les en-têtes entrants.
- L'Operator Keycloak et le serveur partagent le namespace applicatif ; contrôler le RBAC et l'accès aux CR.
- Une synchronisation répliquée ne remplace pas une sauvegarde.
- Le mode `preferred` de CNPG privilégie la continuité et peut dégrader la durabilité en cas de perte de tous les standbys ; évaluer `required` si le RPO prime, en tenant compte du risque de blocage des écritures.
- Le correctif AppArmor est spécifique et conditionnel, pas un réglage universel.
- Trois instances sur un seul cluster ne protègent pas contre la perte complète du cluster, du site ou du réseau de stockage.

## Publication et configuration locale

Le dépôt ne contient que `config.env.example`, avec des adresses IP de documentation et des FQDN d’exemple. Remplacer ces valeurs avant le déploiement. Ne jamais committer `config.env`, `secrets.env`, des certificats, des kubeconfigs, des keytabs ou des manifestes contenant des données propres à un cluster.

Les IP du bloc `192.0.2.0/24` sont réservées à la documentation (TEST-NET-1). Les domaines sous `example.com` sont des noms d’exemple.

## 18. Validation du kit

Les contrôles statiques effectués avant livraison et leurs limites sont documentés dans `AUDIT.md` à la racine. Ils comprennent la syntaxe Bash, la compilation Python, l'analyse YAML et la cohérence des références de scripts/fichiers. L'audit distingue les tests réellement exécutés des contrôles d'intégration qui restent à mener sur une préproduction.

**Le kit n'a pas été exécuté sur un environnement neuf ni sur un cluster réel dans le cadre de sa production.** Les étapes d'installation sont donc à qualifier sur préproduction avant usage de production, en particulier la combinaison K3s 1.36 / Keycloak 26.8.2.

## 19. Documentation officielle

- [Keycloak 26.8.2 – release](https://www.keycloak.org/2026/11/keycloak-2682-released)
- [Keycloak Operator – installation](https://www.keycloak.org/operator/installation)
- [Keycloak Operator – déploiement](https://www.keycloak.org/operator/basic-deployment)
- [Keycloak Operator – configuration avancée / scheduling](https://www.keycloak.org/operator/advanced-configuration)
- [Keycloak – configurations supportées](https://www.keycloak.org/server/supported-configurations)
- [CloudNativePG 1.30 – installation](https://cloudnative-pg.io/docs/1.30/installation/)
- [CloudNativePG 1.30 – failover et quorum](https://cloudnative-pg.io/docs/1.30/failover/)
- [Longhorn 1.13 – documentation](https://longhorn.io/docs/1.13.0/)
- [cert-manager – installation Helm](https://cert-manager.io/docs/installation/helm/)
- [K3s – documentation](https://docs.k3s.io/)


## Préservation de l'adresse IP cliente à l'entrée

Le `HelmChartConfig` Traefik livré par `scripts/02b-configure-ingress.sh` fixe explicitement `service.spec.externalTrafficPolicy: Local`. Cela évite la translation d'adresse source réalisée par le chemin Service Kubernetes en mode `Cluster` et permet à Traefik de recevoir l'adresse source réelle de la connexion. Les trois réplicas Traefik sont soumis à une anti-affinité obligatoire : le déploiement doit donc disposer d'un pod Traefik prêt sur chacun des trois nœuds qui peuvent porter la VIP Ingress. Le script de configuration échoue si le Service ne reste pas en mode `Local` ; `scripts/10-check.sh` signale également toute régression.

Ne pas activer `forwardedHeaders.insecure` pour résoudre un problème d'adresse IP : les en-têtes `X-Forwarded-*` envoyés par un client non approuvé ne doivent pas devenir une source de confiance. La terminaison TLS reste directement sur Traefik ; aucun reverse proxy intermédiaire n'est présumé par ce kit.
## Cycle de vie et mises à niveau

Les procédures de mise à niveau post-déploiement sont séparées des scripts de bootstrap. Lire [`docs/UPGRADE.md`](docs/UPGRADE.md) et utiliser exclusivement les scripts version-ciblés du répertoire [`upgrade/`](upgrade/). Ne pas relancer un script d’installation initiale pour mettre à jour un composant existant.

## Gestion des mises à niveau

Les mises à niveau post-déploiement sont traitées par les procédures dédiées de `upgrade/` et documentées dans `docs/UPGRADE.md`. Commencer par `upgrade/00-inventory.sh` puis `upgrade/01-preflight.sh`. Les scripts sont en simulation par défaut (`--plan`) et exigent `--apply` explicitement. Les composants critiques demandent des preuves de sauvegarde vérifiées. Ne pas relancer les scripts de bootstrap pour mettre à jour une installation existante.
