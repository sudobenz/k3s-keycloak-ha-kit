# Exploitation via Portainer

Ce kit peut être administré depuis Portainer une fois le namespace et les ressources créés.

## Ressources visibles dans Portainer

- Namespace `keycloak`.
- Deployments `keycloak-operator` et Keycloak (géré par l'Operator).
- Cluster CloudNativePG `keycloak-db` et ses pods.
- Secret `keycloak-db-credentials`, Secret `keycloak-initial-admin`, Secret `keycloak-tls`.
- Service `keycloak-service` et Service CNPG `keycloak-db-rw`.
- Ingress `keycloak`.
- CRD/Custom Resources `Keycloak` et `Cluster`.

## Création manuelle d'un Secret TLS

Dans le namespace `keycloak`, créer un Secret de type TLS :

- Nom : `keycloak-tls`
- `tls.crt` : fullchain PEM
- `tls.key` : clé privée PEM

Le certificat doit contenir le FQDN Keycloak dans ses Subject Alternative Names. Ne pas réutiliser un Secret provenant d’une autre application sans contrôler le SAN.

## GitOps Portainer

Si le dépôt est privé, connecter Portainer à ce dépôt et gérer les manifestes non sensibles `output/keycloak.yaml` et `output/keycloak-ingress.yaml` après génération et revue. Le fichier `output/keycloak-postgres.yaml` contient la CR CNPG. Les scripts de bootstrap de secrets et de TLS restent exécutés par un compte d'administration sécurisé, ou sont remplacés par un coffre/secrets manager.

Ne jamais mettre `secrets.env`, les certificats PEM, clés privées, keytabs ou fichiers kubeconfig dans Git.


## Edge Agent (optionnel)

Le kit ne déploie pas un serveur Portainer. Pour rattacher ce cluster à une instance Portainer existante :

1. créer/générer un environnement Kubernetes Edge Agent depuis la console Portainer ;
2. sélectionner l'option Kubernetes et le mode Edge Agent correspondant à la version du serveur ;
3. télécharger le manifeste, le relire et contrôler son namespace, ses endpoints et ses tokens ;
4. le placer dans `portainer/portainer-agent-edge-k8s.yaml` sur le nœud d'administration ;
5. définir `PORTAINER_NAMESPACE` et, si nécessaire, le proxy dans `config.env` ;
6. lancer `bash scripts/15-integrate-portainer.sh`.

Le manifeste Edge Agent contient des informations de rattachement propres à l'instance Portainer. Ne pas le publier dans un dépôt public ni le partager sans protection. Le script ne génère pas ces informations et refuse d'appliquer un manifeste absent.
