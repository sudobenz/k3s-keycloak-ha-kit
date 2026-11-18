# Revue de sécurité – points de passage avant production

- Ne pas utiliser le certificat autosigné du bootstrap pour les utilisateurs finaux.
- Changer le compte admin initial généré par l'Operator ; protéger les administrateurs par MFA et comptes nominatifs.
- Conserver `secrets.env`, kubeconfig, mot de passe DB, keytab et certificats privés dans un coffre ; ne pas committer ces fichiers.
- Donner le moins de droits possible aux opérateurs humains sur les CR Keycloak : toute personne capable de créer/modifier les CR Operator doit être considérée comme administrateur du namespace, car l'image et les références Secret sont des paramètres sensibles.
- Le CR Keycloak limite le flux HTTP d'entrée au namespace `kube-system` via `networkPolicy.http`. Cette fonction de l'Operator est Preview dans la version documentée : vérifier son application réelle, le support NetworkPolicy du CNI et la namespace réelle de Traefik avant production.
- Restreindre l'accès réseau direct au Service Keycloak afin de protéger la confiance dans les en-têtes `X-Forwarded-*`.
- Vérifier que Traefik écrase les en-têtes proxy injectés par le client et que seul le listener `websecure` est exposé si le port 80 est volontairement désactivé.
- Restreindre l'accès à la console et au realm `master` par réseau, VPN ou middleware contrôlé ; ne pas exposer publiquement les fonctions d'administration sans besoin.
- Définir une politique de sauvegarde externalisée et tester la restauration.
- Surveiller expiration TLS, erreurs LDAP/Kerberos, erreurs de DB, latence, disponibilité, authentifications en échec, occupation mémoire et redémarrages.
- Évaluer l'impact du proxy d'entreprise, DNS, NTP, pare-feu et règles egress sur les connexions LDAP/Kerberos/SMTP/IdP.
- K3s 1.36 doit faire l'objet de tests de qualification spécifiques, car il n'est pas dans la plage Kubernetes/OpenShift officiellement testée indiquée par Keycloak sur sa page de configurations supportées.


## Réseau Keycloak / proxy

Le mode `proxy.headers: xforwarded` suppose que Traefik est le seul frontal de confiance. Restreindre l'accès au Service ClusterIP Keycloak depuis les réseaux non fiables et contrôler le comportement de réécriture des en-têtes X-Forwarded. Ne pas exposer le port HTTP interne 8080 à un réseau utilisateur.

## Comptes d'administration

Le Secret `keycloak-initial-admin` est un identifiant bootstrap, pas un compte d'exploitation durable. Changer son mot de passe dès la première connexion, créer des comptes nominatifs, activer MFA et conserver un compte de secours sous coffre. Limiter le realm `master` aux administrateurs.


## Sources de manifests distants

Le script `02-install-vips.sh` épingle l'image kube-vip, mais récupère actuellement le manifeste RBAC depuis `https://kube-vip.io/manifests/rbac.yaml`. Ce contenu est distant et non versionné dans l'archive. Pour une chaîne de livraison strictement reproductible, examiner ce YAML avant application et le vendorer dans le dépôt après revue ; ne pas considérer le seul tag d'image comme un pin complet de toutes les ressources kube-vip.
