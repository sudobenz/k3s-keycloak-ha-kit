# Politique de sécurité

Ces dépôts contiennent des scripts d’installation et d’exploitation d’infrastructures Kubernetes. Ne publiez jamais dans une issue ou une pull request :

- mots de passe, tokens, secrets Kubernetes ou clés API ;
- kubeconfig, certificats/CA privés, clés PEM/PFX/JKS, keytabs ;
- manifestes Portainer Edge Agent ou tout fichier de jumelage ;
- IP, FQDN, noms d’hôtes, DN/realm, chemins ou journaux propres à une infrastructure privée ;
- sauvegardes PostgreSQL/etcd/Longhorn ou données exportées.

Pour signaler une vulnérabilité, contactez le mainteneur par un canal privé avant toute divulgation publique. N’utilisez pas les issues publiques pour les détails exploitables.
