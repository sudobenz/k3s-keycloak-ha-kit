# Observabilité Keycloak / PostgreSQL

Le kit ne déploie pas automatiquement Prometheus, Grafana ou Loki : les choix de rétention, stockage, exposition et alerting dépendent des exigences locales. `prometheus-values.example.yaml` est un exemple de valeurs Helm, pas un déploiement autonome.

## Indicateurs à surveiller

### Keycloak

- disponibilité des pods et de `/health/ready` ;
- taux de requêtes HTTP par statut, latence et erreurs ;
- JVM heap/non-heap, GC, threads, CPU/mémoire, redémarrages ;
- sessions, erreurs d'authentification, événements Admin, cache et connexions DB ;
- erreurs LDAP/LDAPS, Kerberos/SPNEGO et SMTP selon les fonctions activées.

Activer les métriques Keycloak avec les options supportées par la CR de la version déployée, puis contrôler le port/Service exposé avant de créer une ressource de scraping. Ne pas appliquer un ServiceMonitor si Prometheus Operator/CRD n'est pas installé.

### CloudNativePG

- nombre d'instances Ready, rôle primaire/standby, failover et réplication ;
- lag WAL, transactions, connexions, saturation, checkpoints et espace disque ;
- état sauvegarde Barman, archivage WAL, durée de backup et dernier restore test.

Le plugin Headlamp CNPG est utile pour l'administration et le diagnostic interactif, mais ne remplace pas une supervision historique avec alertes.

### TLS / Traefik / Longhorn

- expiration et renouvellement des certificats ;
- réponses 4xx/5xx, débit et latence Ingress ;
- volume Longhorn faulted/degraded, capacité, réplicas, attach/detach et latence.

Les alertes d'expiration doivent couvrir aussi les certificats LDAPS/AD et les keytabs Kerberos, si utilisés.
