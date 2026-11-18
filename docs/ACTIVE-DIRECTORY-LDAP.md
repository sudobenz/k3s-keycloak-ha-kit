# Fédération Active Directory avec Keycloak

Ce document décrit la configuration de fédération à réaliser dans la console d'administration Keycloak après le déploiement initial. Les DN, FQDN de DC, CA et identifiants doivent être remplacés par ceux de l'annuaire réel ; aucune valeur AD n'est inventée dans le kit.

## 1. Préparer Active Directory

Créer un compte technique dédié à la lecture de l'annuaire (exemple de nom uniquement : `svc_keycloak_ldap`). Ne pas utiliser un compte Domain Admin.

Déterminer et documenter :

- domaine DNS / realm Kerberos (ex. `ad.exemple.local`, uniquement illustratif) ;
- FQDN des contrôleurs de domaine ;
- port LDAP/LDAPS ;
- Base DN ;
- Users DN et Groups DN ;
- Bind DN du compte technique ;
- attributs d'identité et de groupes à publier ;
- CA racine et intermédiaires qui signent les certificats LDAPS.

## 2. Préparer la confiance LDAPS

Privilégier LDAPS sur `636` ou StartTLS sur `389`, avec validation du certificat côté Keycloak. Ne pas désactiver la validation du certificat pour résoudre une erreur TLS.

Si la CA interne n'est pas déjà approuvée par l'image runtime, stocker le certificat CA dans un Secret ou ConfigMap du namespace `keycloak`, puis le déclarer dans `spec.truststores` de la ressource `Keycloak` selon la documentation Operator. Un exemple de structure est présenté dans la documentation officielle Advanced Configuration. Le fichier PEM fourni doit contenir le certificat CA, pas la clé privée d'une CA.

## 3. Créer le provider LDAP dans la console

Dans le realm cible :

1. Ouvrir **User Federation** puis **Add LDAP providers**.
2. Choisir **Vendor: Active Directory**.
3. Renseigner **Connection URL** avec `ldaps://<dc-fqdn>:636`.
4. Renseigner **Bind Type: simple**, le Bind DN du compte technique et son mot de passe.
5. Renseigner Users DN, Username LDAP attribute (`sAMAccountName` le plus souvent), UUID LDAP attribute (`objectGUID` pour AD) et les paramètres d'édition/synchronisation choisis.
6. Utiliser les boutons **Test connection** et **Test authentication**.
7. Ajouter les mappers de groupes et d'attributs nécessaires, puis tester sur un compte pilote.
8. Définir la périodicité de synchronisation et la politique de suppression/désactivation des comptes en fonction des exigences métiers.

Ne pas activer l'écriture vers AD sans décision explicite : le mode par défaut doit rester lecture seule lorsque Keycloak n'a pas vocation à administrer l'annuaire.

## 4. Contrôles

- Un utilisateur pilote est trouvé depuis Keycloak.
- Les attributs nom, prénom, e-mail et identifiant correspondent à AD.
- Les appartenances aux groupes sont correctement importées.
- Un mot de passe invalide est rejeté.
- Un contrôleur de domaine indisponible ne bloque pas indéfiniment les requêtes ; ajuster timeout et failover LDAP.
- Le certificat LDAPS est validé sans désactiver la vérification TLS.

## 5. SPNEGO / Kerberos

Pour activer l'authentification intégrée navigateur, suivre `KERBEROS-SPNEGO.md` après validation de la fédération LDAP. La fédération LDAP seule ne déclenche pas automatiquement SPNEGO.

Référence : [Keycloak Server Administration – LDAP and Active Directory](https://www.keycloak.org/docs/26.8.2/server_admin/).
