# TLS et Traefik

## Mode retenu

Le certificat public est terminé par Traefik sur la VIP Ingress `192.0.2.55:443`. Le trafic Traefik -> Service Keycloak est en HTTP dans le réseau du cluster, sur le port `8080`.

Le CR Keycloak doit donc contenir `http.httpEnabled: true`, un `hostname.hostname` public en `https://`, et `proxy.headers: xforwarded`. Les requêtes arrivent au Service `keycloak-service:8080`.

## Certificat existant

Le Secret `keycloak-tls` doit être dans le namespace `keycloak` et contenir `tls.crt` et `tls.key`. Le certificat doit inclure le FQDN Keycloak dans ses SAN. Le kit ne copie aucun Secret depuis un autre namespace ou une autre installation : le certificat doit être explicitement vérifié pour le SAN Keycloak.

Pour importer via Portainer, créer un Secret de type `kubernetes.io/tls` avec les champs `tls.crt` (fullchain PEM) et `tls.key` (clé privée). Pour une installation automatisée, utiliser le mode `files` du script `scripts/07-prepare-tls-secret.sh`.

## Proxy headers

Keycloak est configuré pour `xforwarded`. Traefik doit remplacer les en-têtes `X-Forwarded-*` entrants par ses propres valeurs. Le manifeste généré par `scripts/08-deploy-keycloak.sh` limite le flux HTTP d'entrée au namespace `kube-system`, où le Traefik embarqué K3s est déployé. Ce réglage s'appuie sur les règles `networkPolicy.http` de l'Operator Keycloak ; la prise en charge des NetworkPolicies dans le CR est signalée comme Preview dans la documentation de la version 26.8.x. Vérifier que le CNI applique les NetworkPolicies, que Traefik reste bien dans `kube-system` et que les probes continuent à fonctionner. Si le déploiement utilise un autre namespace/Ingress Controller, adapter le selector avant application. Ne pas considérer cette restriction comme validée tant qu'elle n'a pas été testée dans le cluster cible.

Références :
- [Keycloak reverse proxy](https://www.keycloak.org/server/reverseproxy)
- [Keycloak hostname v2](https://www.keycloak.org/server/hostname)
