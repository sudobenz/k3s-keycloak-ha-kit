# Sauvegarde et restauration Keycloak / CNPG

## Dump logique fourni

Exécuter `scripts/12-backup-db.sh`. Le dump PostgreSQL custom est enregistré dans `backups/` avec un checksum SHA-256. Copier immédiatement ce fichier sur un stockage externe chiffré et soumis à une politique de rétention.

## Restauration logique (procédure indicative)

Vérifier le checksum avant toute restauration :

```bash
sha256sum -c backups/keycloak-<timestamp>.dump.sha256
```

La restauration doit être testée sur un cluster Keycloak de préproduction ou dans une nouvelle base. Ne pas restaurer directement par-dessus la base de production en service.

Exemple de restauration vers une base vide après création d'un rôle/base compatibles :

```bash
pg_restore --no-owner --no-acl --clean --if-exists \
  --username=keycloak --dbname=keycloak /chemin/keycloak.dump
```

Adapter l'hôte, TLS et l'authentification PostgreSQL au contexte d'exécution. Un dump `pg_dump` ne contient pas les rôles globaux PostgreSQL créés en dehors de la base ; les credentials du rôle `keycloak` doivent donc être sauvegardés séparément dans un coffre. Une restauration dans le même cluster CNPG peut nécessiter un pod client temporaire ou `kubectl exec` vers une instance ; protéger les mots de passe et ne pas les passer en argument de commande en production. Ne jamais restaurer directement sur une base Keycloak active.

## Sauvegardes physiques recommandées

Configurer `spec.backup` CNPG avec Barman Cloud et un ObjectStore externe. Les informations S3, le bucket, la région, le endpoint, le Secret et la rétention n'ont pas été fournis, donc aucune politique Barman inventée n'est embarquée.

Sauvegarder également :

- les manifests Keycloak (CR, Operator ref, Ingress) ;
- les Secrets de bootstrap/DB/TLS/LDAP/Kerberos via un coffre approprié ;
- les CRD et la configuration CNPG ;
- les snapshots/volumes Longhorn selon les objectifs RPO/RTO ;
- les snapshots etcd K3s et la procédure de restauration complète.

La réplication CNPG n'est pas une sauvegarde. Tester à intervalle régulier une restauration complète et mesurer le RTO.
