# Checklist de qualification avant production

Cette checklist doit être signée après validation sur une préproduction représentative. Les vérifications de syntaxe du kit ne valent pas qualification fonctionnelle.

## Infrastructure

- [ ] Trois nœuds indépendants, IP statiques, NTP et DNS contrôlés.
- [ ] VIP API et VIP Ingress réservées ; test ARP/Kube-VIP après panne d'un nœud.
- [ ] Trois membres etcd sains ; snapshots automatiques présents et copie externe testée.
- [ ] Règles pare-feu validées depuis les réseaux d'administration, utilisateurs et inter-nœuds.
- [ ] Disques Longhorn dédiés, montés au boot, ext4/XFS, capacité et alertes définies.
- [ ] Longhorn Node/Disks Ready ; StorageClass PG vérifiée ; test PVC/reattach effectué.
- [ ] K3s/AppArmor qualifié sur la version exacte des hôtes ; aucun correctif AppArmor appliqué sans diagnostic.

## Stockage et PostgreSQL

- [ ] Trois instances CNPG sur trois nœuds distincts.
- [ ] Primary/standby, réplication et retard WAL contrôlés.
- [ ] Politique sync `preferred` ou `required` choisie après validation du compromis disponibilité/durabilité.
- [ ] Failover quorum vérifié, événements et logs audités.
- [ ] Sauvegarde Barman Cloud externe, chiffrement, rétention et archivage WAL configurés.
- [ ] Restauration dans une nouvelle base/cluster testée ; RPO/RTO mesurés.

## Keycloak

- [ ] Trois pods Keycloak Ready sur trois nœuds distincts.
- [ ] Operator Ready ; CR Keycloak Ready ; image serveur alignée sur Operator.
- [ ] Service DB `keycloak-db-rw` stable ; saturation et pool de connexions mesurés.
- [ ] Test d'arrêt d'un pod Keycloak ; requêtes OIDC continuent via Traefik.
- [ ] Test de panne d'un nœud ; contrôle du failover CNPG et des sessions.
- [ ] Test de mise à jour et plan de retour documentés.
- [ ] Compte administrateur initial remplacé ; MFA ; comptes nominatifs ; compte de secours sous coffre.
- [ ] Realm master protégé ; clients OIDC/SAML revus ; politiques de tokens et sessions définies.

## TLS / DNS / réseau

- [ ] Certificat public valide et chaîne complète approuvée par les postes clients.
- [ ] SAN correct ; renouvellement automatique cert-manager testé ou synchronisation externe documentée.
- [ ] Si port 80 fermé, challenge DNS-01 configuré et renouvellement testé.
- [ ] Traefik termine TLS ; en-têtes `X-Forwarded-*` écrasés par le proxy.
- [ ] Service Keycloak non accessible depuis un réseau non fiable hors Traefik.
- [ ] DNS public/interne et découverte OIDC correspondent au hostname strict.

## Annuaire / authentification

- [ ] LDAP/LDAPS avec CA vérifiée ; compte AD dédié, lecture seule.
- [ ] Import/synchronisation utilisateurs, attributs et groupes validés.
- [ ] Politique de désactivation/suppression des utilisateurs AD testée.
- [ ] SPN et keytab Kerberos validés si SPNEGO activé ; renouvellement du keytab documenté.
- [ ] GPO navigateurs intégrées testées sur un groupe pilote.

## Observabilité / exploitation

- [ ] Métriques, logs, alertes, expiration certificats, erreurs LDAP et erreurs DB supervisés.
- [ ] Runbooks de bascule, restauration, changement de certificat et mise à jour validés.
- [ ] Procédure de maintenance un nœud à la fois, PDB/volumes strict-local compris.
- [ ] Secrets, kubeconfig, certificats et keytabs stockés dans un coffre avec rotation définie.
- [ ] Revue RBAC et accès Portainer/Headlamp réalisée.

## Qualification du support

- [ ] Combinaison K3s 1.36 / Keycloak 26.8.2 qualifiée en environnement cible, compte tenu du statut best-effort des distributions Kubernetes non-OpenShift dans la matrice Keycloak.
