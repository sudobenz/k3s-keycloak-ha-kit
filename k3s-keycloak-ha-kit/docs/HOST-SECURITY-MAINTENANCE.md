# Protection des hôtes et maintenance du cluster K3s / Keycloak

## 1. Périmètre constaté dans ce kit

- Trois nœuds K3s serveurs/etcd : `k3s-1`, `k3s-2`, `k3s-3`.
- K3s, Longhorn et CloudNativePG sont répartis sur ces trois hôtes.
- CloudNativePG exécute trois instances PostgreSQL dans le namespace `keycloak`.
- La StorageClass PostgreSQL `longhorn-pg-local` utilise `dataLocality: strict-local` et une seule réplique Longhorn par volume. La disponibilité de PostgreSQL repose donc sur la réplication CloudNativePG, pas sur plusieurs copies Longhorn d'un même volume.
- Keycloak dispose de trois réplicas.
- Le kit contient déjà `scripts/patchmon-precheck.sh` et `scripts/patchmon-postcheck.sh`. Ils sont des garde-fous, pas un moteur d'installation automatique des mises à jour.

## 2. Décisions de protection

| Contrôle | Décision | Portée / raison |
|---|---|---|
| Fail2ban | **À installer** | Uniquement le service SSH de chaque hôte, avec backend systemd. |
| Fail2ban sur Keycloak/HTTP | **Ne pas configurer** | Les journaux applicatifs ne sont pas des journaux SSH de l'hôte; Fail2ban ne doit pas être branché à des logs de conteneurs non qualifiés. |
| Détection de force brute Keycloak | **À activer** | Contrôle natif au niveau du realm, avec verrouillage temporaire et seuils testés. |
| Rate limiting Traefik global | **Ne pas activer par défaut** | Sans stockage de compteurs partagé, les trois réplicas Traefik ne disposent pas d’un compteur global; un seuil arbitraire peut aussi bloquer des utilisateurs légitimes. |
| CrowdSec / sshguard en plus de Fail2ban | **Ne pas empiler** | Un seul mécanisme de bannissement SSH est configuré dans ce kit. Ne pas faire piloter plusieurs moteurs de bannissement sans règles de priorité et de déblocage testées. |
| UFW / pare-feu hôte générique | **Ne pas activer automatiquement** | Un profil générique risque de couper API K3s, etcd, Flannel, kubelet ou les flux iSCSI/Longhorn. Appliquer les ACL sur le réseau/hyperviseur après validation de la matrice réseau. |
| AppArmor | **Conserver** | Ne pas appliquer de correctif global. `fix-k3s-apparmor-stacked-peer.sh` reste conditionnel au diagnostic documenté dans `APPARMOR-K3S.md`. |
| NetworkPolicy Kubernetes | **Ne pas ajouter de politique globale** | Conserver les politiques déjà livrées et valider leur effet réel avec le CNI et Traefik. |
| Mises à jour APT automatiques | **Désactivées par défaut** | Les installations de paquets doivent être coordonnées entre les trois nœuds. |
| Redémarrage automatique | **Désactivé** | Aucun nœud etcd/CNPG ne doit redémarrer sur le seul déclenchement local d'APT. |

## 3. Installer la protection hôte

Avant d'exécuter le script, éditer `config.env` sur chaque hôte et renseigner `FAIL2BAN_IGNORE_IPS` avec les adresses ou réseaux réels depuis lesquels l'administration SSH est autorisée. La liste est obligatoire : ne pas reprendre les exemples de documentation comme valeurs réelles.

Exemple de syntaxe uniquement :

```bash
FAIL2BAN_IGNORE_IPS="192.0.2.10/32,192.0.2.0/24,2001:db8::/64"
FAIL2BAN_SSH_PORT="ssh"
```

Si SSH utilise un port non standard, remplacer `ssh` par son numéro TCP réel. Appliquer sur **chacun des trois hôtes** :

```bash
sudo bash scripts/configure-host-protection.sh
sudo bash scripts/check-host-protection.sh
```

Le script, prévu pour les hôtes Ubuntu/Debian du kit, installe `fail2ban` et `python3-systemd`, active uniquement le jail `sshd`, et écrit une surcharge APT qui désactive l'installation autonome de mises à jour et les redémarrages automatiques. Fail2ban ajoute ses propres règles de bannissement SSH via son action système ; le script ne remplace ni ne vide le ruleset, ne modifie pas `sshd_config`, n'active pas UFW et ne touche pas aux règles réseau K3s ou aux services K3s/Longhorn.

Avant de laisser Fail2ban en production, vérifier que l'adresse d'administration effective apparaît bien dans `ignoreip` et tester une nouvelle connexion SSH depuis le réseau d'administration. Garder une session console/hyperviseur disponible pendant ce test.

## 4. Protection propre à Keycloak

Dans la console d'administration Keycloak, pour chaque realm exposé à l'authentification utilisateur :

1. Ouvrir **Realm settings → Security defenses → Brute force detection**.
2. Activer la détection de force brute.
3. Choisir des seuils modérés et un verrouillage temporaire adaptés aux utilisateurs et aux flux MFA; éviter le verrouillage permanent sans processus de déblocage exploité.
4. Tester les flux mot de passe, OTP, récupération de compte, comptes de service et fédération LDAP/AD avant généralisation.

Conserver l'accès d'administration au realm `master` limité au réseau/VPN d'administration et à des comptes nominatifs protégés par MFA. Traefik doit rester le frontal de confiance; le Service Keycloak ne doit pas être accessible directement depuis des réseaux non fiables. Ne faire confiance aux en-têtes `X-Forwarded-*` que lorsqu'ils sont réécrits par le frontal autorisé.

Ne pas déployer un jail Fail2ban HTTP sur la base de logs applicatifs sans pipeline explicite, format de logs stable, source IP fiable et test anti-faux positifs.

## 5. Politique de mises à jour hôte : ce qui est possible et ce qui ne l'est pas

### Configuration sûre fournie

- Les listes APT peuvent être rafraîchies; les mises à jour de paquets ne sont pas installées automatiquement par `unattended-upgrades`.
- Aucun redémarrage automatique n'est autorisé.
- PatchMon peut rester utilisé pour inventorier les hôtes et piloter une action ciblée sur un hôte.
- Les scripts PatchMon du kit contrôlent l'état du cluster avant/après maintenance.

### Limite à ne pas contourner

Une politique PatchMon de groupe qui met à jour les trois hôtes n'est **pas** cluster-aware. Elle peut démarrer des actions sur plusieurs hôtes sans attendre le retour complet du quorum etcd, des volumes Longhorn et des instances CNPG. De plus, l'action Linux `patch_all` de PatchMon n'offre pas de dry-run; elle peut mettre à jour l'ensemble des paquets obsolètes, pas uniquement un sous-ensemble de sécurité. Les scripts de pré/post-contrôle du kit ne sont pas des hooks PatchMon qui bloquent automatiquement l'exécution.

En conséquence : **ne pas planifier une politique `patch_all` simultanée sur le groupe des trois nœuds** et ne pas activer `unattended-upgrades` avec redémarrage autonome. Pour PatchMon, préférer une mise à jour `patch_package` par hôte avec dry-run, revue des dépendances puis approbation; `patch_all` Linux ne peut pas être dry-run. Ne pas confondre une politique horaire PatchMon avec une barrière de santé Kubernetes.

Pour obtenir une autonomie réellement sûre, l'orchestrateur externe doit être hors du cluster et doit, pour chaque hôte : (1) prendre un snapshot etcd et vérifier la sauvegarde CNPG hors cluster; (2) vérifier quorum etcd, trois nœuds Kubernetes/Longhorn Ready et toutes les ressources applicatives/volumes sains; (3) refuser le primaire CNPG ou effectuer un switchover planifié vérifié; (4) cordon/drain les charges évictables en excluant les pods `cnpg.io/cluster`; (5) mettre à jour un seul hôte; (6) redémarrer uniquement si nécessaire; (7) attendre Node Ready puis Longhorn Node Ready, réintégrer le nœud et attendre le retour des trois instances CNPG, des trois réplicas Keycloak et de l'endpoint OIDC; (8) ne passer au nœud suivant qu'après tous les contrôles verts. Tout délai dépassé ou état dégradé doit arrêter la séquence et laisser le nœud en état de maintenance. Ce composant externe n'est pas déployé par le kit fourni : **les mises à jour restent donc déclenchées et autorisées par un opérateur**, pas autonomes de bout en bout.

## 6. Procédure de maintenance séquentielle avec PatchMon

À exécuter depuis un nœud serveur K3s qui reste Ready et qui n'est pas le nœud en maintenance (de préférence `k3s-1`). Les scripts utilisent le binaire local `k3s` et `/etc/rancher/k3s/k3s.yaml`; le kit `config.env` doit être présent sur le nœud d'administration. Si la cible est `k3s-1`, exécuter les contrôles depuis `k3s-2` ou `k3s-3`. Les commandes concernent **un seul hôte par cycle**.

### 6.1 Avant les mises à jour

1. Vérifier que les trois nœuds sont `Ready`, que l'API K3s est `readyz=ok`, que les trois pods PostgreSQL sont sains, que Keycloak est disponible et que les volumes Longhorn sont `healthy`.
2. Vérifier qu'une sauvegarde etcd récente et une sauvegarde PostgreSQL exploitable existent hors du cluster. Un snapshot Longhorn n'est pas une sauvegarde applicative et ne remplace pas une sauvegarde CNPG.
3. Depuis le répertoire du kit :

```bash
sudo bash scripts/patchmon-precheck.sh k3s-2
```

Remplacer `k3s-2` par le nom du seul nœud retenu. Si le nœud héberge le primaire CNPG, le script bloque. Effectuer alors un **switchover planifié** vers une instance de secours saine avec la procédure CloudNativePG validée, puis relancer le pré-contrôle. Ne pas supprimer ni drainer le primaire pour provoquer un basculement.

### 6.2 Cordon et drain

Après succès du pré-contrôle, appliquer exactement les commandes affichées. Le drain fourni exclut les pods portant le label `cnpg.io/cluster` : ils restent attachés à leurs volumes strict-local sur leur nœud et redémarrent/rejoignent le cluster après retour de l'hôte.

```bash
sudo k3s kubectl cordon k3s-2
sudo k3s kubectl drain k3s-2 --ignore-daemonsets --delete-emptydir-data --pod-selector='!cnpg.io/cluster' --timeout=10m
```

Si le drain est bloqué par un PodDisruptionBudget, un volume Longhorn, une dernière réplique ou un pod non évictable : **arrêter**. Conserver la politique Longhorn de protection de la dernière réplique saine; ne pas la remplacer par `Always Allow` pour forcer un drain. Ne pas utiliser `--disable-eviction`, `--force` ou supprimer un pod CNPG pour faire passer le drain. Examiner `kubectl describe node`, les PDB, les pods Longhorn et les CR `Volume`/`Node` Longhorn.

### 6.3 Mise à jour et redémarrage éventuel

Dans PatchMon, cibler uniquement l'hôte cordonné. Ne lancer aucune action sur un deuxième hôte tant que le post-contrôle du premier n'est pas terminé.

Si un redémarrage est requis :

- vérifier que le patch est terminé et que le gestionnaire de paquets n'est plus actif;
- laisser le nœud cordonné et les charges applicatives évictables drainées;
- redémarrer uniquement ce nœud depuis PatchMon ou la console de l'hyperviseur;
- ne pas forcer un redémarrage si `dpkg`/APT travaille encore;
- ne jamais redémarrer un deuxième serveur K3s pendant cette récupération.

Si aucun redémarrage n'est requis, passer directement au post-contrôle.

### 6.4 Réintégration et post-contrôle

Après retour du système, exécuter depuis le nœud d'administration :

```bash
sudo bash scripts/patchmon-postcheck.sh k3s-2
```

Le script attend le retour `Ready` de Kubernetes **et** du nœud Longhorn avant de faire `uncordon`, puis exige que les contrôles complets Keycloak, CNPG et Longhorn passent. En cas d'échec après `uncordon`, le script tente de re-cordonner le nœud si l'API est disponible; le cycle s'arrête : ne pas maintenir le nœud suivant. Vérifier également côté OS `systemctl is-active k3s`, `systemctl is-active iscsid`, le montage `/var/lib/longhorn` et l'absence d'erreur AppArmor/containerd.

Ne commencer le nœud suivant que lorsque les trois nœuds sont `Ready`, les trois instances PostgreSQL sont `Ready`, Keycloak dispose de ses trois réplicas, les volumes Longhorn sont sains et l'endpoint HTTPS/OIDC répond.

## 7. Redémarrages et mises à niveau à traiter séparément

- **Paquets OS / noyau** : procédure séquentielle ci-dessus; le redémarrage dépend de `/var/run/reboot-required` et des paquets concernés.
- **K3s** : ne pas le traiter comme une simple mise à jour APT. Conserver la version épinglée dans `config.env` et appliquer une procédure K3s dédiée, serveurs un par un, avec validation de la version et du quorum entre chaque nœud.
- **Longhorn / CNPG / Keycloak** : mises à niveau séparées des paquets OS. Respecter les procédures de version, snapshots et sauvegardes de chaque composant.
- **AppArmor** : ne pas relancer automatiquement le correctif à chaque mise à jour; diagnostiquer le profil et le noyau au préalable.

## 8. Références opérationnelles

- Réseau et ports : `NETWORK-FIREWALL.md`.
- Sécurité Keycloak : `SECURITY.md`.
- Sauvegarde et restauration : `BACKUP-RESTORE.md`.
- Versions applicatives : `UPGRADE.md`.
- Correctif AppArmor : `APPARMOR-K3S.md`.
- Documentation officielle : [PatchMon Admin Guide](https://patchmon.net/docs/patchmon-admin-guide), [Ubuntu unattended-upgrades](https://ubuntu.com/server/docs/how-to/software/automatic-updates), [K3s automated upgrades](https://docs.k3s.io/upgrades/automated), [Kubernetes Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [Longhorn Node Maintenance](https://longhorn.io/docs/1.13.0/maintenance/maintenance/), [CloudNativePG](https://cloudnative-pg.io/documentation/1.30/).
