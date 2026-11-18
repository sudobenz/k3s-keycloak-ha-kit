# Réseau, DNS et pare-feu

Adapter les flux aux règles réelles de l'hyperviseur, de l'hôte et du réseau. Les ports suivants sont des repères d'architecture, pas une politique universelle.

## Entre les trois nœuds K3s

| Flux | Port/protocole | Utilité |
|---|---:|---|
| API Kubernetes | TCP 6443 | API K3s / jointure / administration |
| etcd | TCP 2379-2380 | quorum etcd embarqué entre serveurs K3s |
| kubelet | TCP 10250 | API kubelet |
| Flannel VXLAN | UDP 8472 | réseau Pod inter-nœuds |
| Longhorn iSCSI | TCP 3260 | attachement bloc iSCSI |
| Longhorn manager | TCP 9500 | communication des moteurs/réplicas |
| DNS | UDP/TCP 53 | résolution |
| NTP | UDP 123 | synchronisation horaire |

Éviter d'exposer les ports du plan de contrôle aux réseaux utilisateurs. Restreindre etcd au seul réseau inter-nœuds.

## Accès utilisateurs / entrée

- `INGRESS_VIP:443/TCP` vers Traefik (HTTPS).
- `INGRESS_VIP:80/TCP` uniquement si `TRAEFIK_ENABLE_HTTP=true` et si une redirection HTTP->HTTPS/HTTP-01 est explicitement voulue.
- `K3S_API_VIP:6443/TCP` depuis les stations d'administration et les systèmes autorisés.

## Préservation de l'adresse IP source

Le Service LoadBalancer Traefik doit rester configuré avec `spec.externalTrafficPolicy: Local` (valeur persistée par le `HelmChartConfig` du kit). Le déploiement Traefik utilise trois réplicas avec anti-affinité obligatoire afin qu'un endpoint local soit disponible sur chacun des trois nœuds susceptibles de porter la VIP. Vérifier cette propriété après toute mise à niveau ou réconciliation Helm. En mode `Cluster`, Kubernetes peut masquer l'adresse source avant que Traefik ne la voie. Ne pas compenser en faisant confiance aux en-têtes `X-Forwarded-*` non vérifiés.

## Sorties depuis les nœuds et pods

- TCP 443 vers les dépôts Ubuntu, GitHub, GHCR, Quay, Docker/OCI registries et endpoints Helm requis.
- TCP 443 depuis l'agent PatchMon vers le serveur PatchMon configuré; le modèle agent PatchMon est sortant et ne nécessite pas de port entrant ouvert sur les nœuds.
- DNS et NTP vers les services internes autorisés.
- Depuis Keycloak vers Active Directory : TCP 636 (LDAPS) ou TCP 389 (LDAP/StartTLS), TCP/UDP 88 et 464 si Kerberos ; DNS SRV et NTP obligatoires pour Kerberos.
- SMTP vers le relais interne, si les notifications e-mail Keycloak sont activées.

Ne pas ouvrir tous les flux par commodité. Construire une matrice source/destination adaptée au CNI, aux règles NetworkPolicy, aux ACL réseau et aux pare-feu hôtes.


## Prérequis iSCSI Longhorn

Longhorn 1.13 nécessite `open-iscsi`, `iscsid` actif et le module noyau `iscsi_tcp`. La version `open-iscsi 2.1.12` est explicitement incompatible avec l'attachement des volumes : utiliser `<=2.1.11` ou `>=2.1.13`. Le préflight d'installation arrête le bootstrap si 2.1.12 est détecté. Ubuntu 26.04 fournit normalement 2.1.11 dans son dépôt de base à la date de ce kit ; vérifier la version réellement installée avant d'aller plus loin.
