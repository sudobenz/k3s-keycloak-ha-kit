# Cycle de vie et mise à jour Keycloak

Le kit épingle le serveur et l'Operator officiel à `26.8.2` (release du 5 novembre 2026). Ne pas remplacer par `latest`.

## Avant toute mise à jour

1. Lire la release note de chaque patch/minor et le guide de migration.
2. Faire une sauvegarde Barman Cloud vérifiée et un dump logique.
3. Tester la nouvelle version dans un environnement de préproduction.
4. Valider les extensions, providers personnalisés, LDAP, Kerberos/SPNEGO, thèmes, clients OIDC/SAML et scripts d'administration.
5. Planifier une fenêtre de maintenance et un plan de retour.

Keycloak modifie le schéma de base lors de certaines mises à jour ; un downgrade vers l'ancienne version n'est pas garanti. La documentation officielle recommande une stratégie de mise à jour manuelle et un backup préalable pour l'Operator.

## Procédure générale

- Comparer les notes de version et les versions Operator/serveur attendues.
- Appliquer la version Operator/CRD selon la procédure officielle, puis mettre à jour la ressource Keycloak avec une version d'image compatible.
- Attendre `Ready=True`, vérifier le nombre de pods, les logs, `/health/ready`, le document OIDC et les tests fonctionnels.
- Ne pas supprimer les CRD à la désinstallation : cela supprimerait les ressources personnalisées associées.

Références :
- https://www.keycloak.org/docs/latest/upgrading/
- https://www.keycloak.org/operator/installation
- https://www.keycloak.org/2026/11/keycloak-2682-released
