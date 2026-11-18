# Audit de livraison — Kit autonome K3s HA + Keycloak

- **Version du kit :** 1.2.2
- **Date de révision :** 18 novembre 2026
- **Périmètre :** audit statique de l'archive et cohérence documentaire.

## Résultat des contrôles exécutés

Commande exécutée depuis la racine du kit :

```bash
bash scripts/validate-kit.sh
```

Résultat : **validation statique réussie, 0 avertissement**.

Contrôles passés :

- syntaxe Bash de l'ensemble des scripts `scripts/*.sh` avec `bash -n` ;
- compilation du script Python `scripts/http-benchmark.py` ;
- analyse syntaxique des 6 fichiers YAML/YML livrés avec PyYAML ;
- vérification des références de scripts présentes dans le README et la documentation ;
- absence de `secrets.env`, de kubeconfig dans la source du kit ;
- absence d'en-tête de clé privée PEM/OPENSSH dans les fichiers du kit ;
- contrôle des références applicatives : aucune référence au produit non livré dans ce dépôt.

Une revue manuelle complémentaire a porté sur le bootstrap K3s, la séquence canonique des étapes applicatives, le déploiement CNPG, l'installation de l'Operator Keycloak officiel, la ressource Keycloak, la terminaison TLS Traefik, l'Ingress Longhorn, Headlamp et Portainer.

## Ce que cette validation ne démontre pas

Cette livraison n'a **pas** été exécutée sur trois machines vierges ni sur un cluster de préproduction. Elle ne constitue donc pas un test d'intégration ou une certification de production.

Les outils `helm`, `kubectl`, `kustomize` et `shellcheck` n'étaient pas installés dans l'environnement de fabrication de l'archive. En conséquence :

- les charts Helm n'ont pas été téléchargés ni rendus localement ;
- les manifestes ne sont pas validés contre les schémas réels de l'API Kubernetes ou des CRD ;
- le Kustomize distant de l'Operator Keycloak n'a pas été téléchargé/appliqué ;
- ShellCheck n'a pas été exécuté.

La validation YAML confirme uniquement que les fichiers sont syntaxiquement analysables, pas que chaque champ est accepté par la version distante de son CRD.

## Réserves à traiter en préproduction

1. **Keycloak sur K3s :** Keycloak décrit les distributions Kubernetes autres qu'OpenShift comme prises en charge au mieux (« best effort »). La combinaison Keycloak 26.8.2 / K3s 1.36.6 doit être qualifiée en préproduction.
2. **NetworkPolicy de l'Operator Keycloak :** le réglage `spec.networkPolicy` utilisé pour limiter les connexions HTTP au namespace Traefik est une fonctionnalité Preview de l'Operator. Vérifier le comportement avec le CNI K3s/Flannel, les probes, les communications nécessaires et les mises à jour de labels/namespace. Le script ne prouve pas à lui seul l'application effective de la politique réseau.
3. **Kube-VIP RBAC :** l'image Kube-VIP est épinglée, mais le script récupère le manifeste RBAC officiel depuis une URL upstream non versionnée. Pour une installation hermétique, archiver et relire une copie du manifeste correspondant à la version retenue.
4. **AppArmor :** le correctif est conditionnel et réservé aux systèmes concernés. La qualification historique est antérieure à la version K3s épinglée dans ce kit ; vérifier le diagnostic et tester sur la version réellement installée avant application.
5. **Portainer Edge Agent :** le manifeste Kubernetes Edge Agent doit être généré depuis l'interface Portainer de l'environnement cible. Il n'est pas fourni car il est spécifique à l'instance Portainer.
6. **Sauvegardes :** le kit fournit un dump logique et une procédure de restauration. Il ne crée pas de bucket S3, de credentials Barman Cloud ni de cible de sauvegarde externe, ces éléments dépendant du fournisseur et du stockage du déploiement.
7. **TLS :** le mode autosigné sert au bootstrap et aux essais. Utiliser une chaîne de confiance valide avant ouverture aux utilisateurs. Le mode cert-manager nécessite un Issuer/ClusterIssuer opérationnel et configuré pour le DNS concerné.
8. **Ressources :** les demandes CPU/mémoire et les paramètres PostgreSQL sont des valeurs de départ. Réaliser des tests de charge représentatifs et ajuster le pool JDBC, la mémoire, les connexions et le stockage.
9. **HA réelle :** trois pods Keycloak et trois instances PostgreSQL ne remplacent pas les tests de panne nœud, de perte de stockage, de bascule du primaire, de partition réseau et de restauration complète.

## Éléments non inclus volontairement

- secrets réels, tokens K3s, mots de passe PostgreSQL ou BasicAuth ;
- kubeconfig, certificats TLS privés, clés privées, CA privée ou keytabs ;
- manifeste Edge Agent Portainer généré pour un serveur particulier ;
- identifiants AD, SPN, DN, realm, données de fédération LDAP/Kerberos ;
- identifiants d'un fournisseur S3 ou d'un service DNS-01.

## Conditions minimales avant production

- exécuter le kit complet sur un cluster de préproduction jetable ;
- tester la perte individuelle de chacun des trois nœuds ;
- vérifier la distribution effective des pods Keycloak et CNPG sur trois hôtes ;
- tester failover PostgreSQL et reconnexion Keycloak ;
- tester expiration/renouvellement TLS ;
- valider LDAP/LDAPS, Kerberos/SPNEGO si activé, et les flux réseau ;
- effectuer une sauvegarde puis une restauration complète ;
- mesurer les ressources et la latence avec une charge IAM représentative ;
- remplacer tous les certificats autosignés avant ouverture utilisateurs ;
- établir une procédure d'upgrade et de rollback testée.


## Extension du 12 novembre 2026 – protection des hôtes et maintenance

- Ajout de `docs/HOST-SECURITY-MAINTENANCE.md` : choix Fail2ban, protection native Keycloak, limites PatchMon et procédure de maintenance séquentielle.
- Ajout de `scripts/configure-host-protection.sh` et `scripts/check-host-protection.sh` : jail SSH Fail2ban avec backend systemd, liste d'exclusion d'administration obligatoire et désactivation de l'installation automatique APT/redémarrage local.
- Renforcement des scripts PatchMon : contrôle des trois volumes CNPG strict-local, Ready des trois ressources Node Longhorn, exclusion des pods CNPG du drain et attente Longhorn avant `uncordon`.
- Ces contrôles sont statiques; aucun changement n'a été appliqué au cluster réel. Le kit ne configure pas un orchestrateur autonome externe de mise à jour OS; cette limite est explicitement documentée parce que PatchMon, seul, ne garantit pas une maintenance cluster-aware.

- Le post-contrôle re-cordonne le nœud si la récupération applicative expire après `uncordon`; cela limite l'ordonnancement de nouvelles charges pendant le diagnostic.


## Correctif complémentaire — conservation de l'IP source Traefik

- `scripts/02b-configure-ingress.sh` persiste `service.spec.externalTrafficPolicy: Local` dans le `HelmChartConfig` K3s/Traefik.
- Le script attend et vérifie explicitement cette valeur après la réconciliation Helm ; il échoue si le Service revient à `Cluster`.
- `scripts/10-check.sh` signale toute régression du Service vers `Cluster`.
- Le README et la matrice réseau documentent la nécessité de conserver un endpoint Traefik prêt sur chacun des nœuds pouvant porter la VIP (trois réplicas avec anti-affinité obligatoire).
- Aucun réglage `forwardedHeaders.insecure`, ni paramètre Kube-VIP supplémentaire n'a été ajouté.
