# Kerberos / SPNEGO avec Active Directory

La configuration SPNEGO est optionnelle et dépend du domaine AD. Le kit ne génère pas de keytab car le SPN, le compte de service, le chiffrement et le realm doivent correspondre à l'Active Directory réel.

## 1. Flux cible

1. Le poste Windows ouvre une session de domaine et obtient un ticket Kerberos.
2. Le navigateur contacte `https://<KEYCLOAK_FQDN>` et est autorisé à négocier Kerberos pour ce FQDN.
3. Le navigateur transmet un ticket SPNEGO à Keycloak.
4. Keycloak vérifie le ticket avec le keytab du compte de service HTTP.
5. Le provider LDAP/AD retrouve l'utilisateur et ses attributs.
6. Keycloak délivre à l'application un jeton OIDC ou une assertion SAML.

## 2. Préparer le SPN dans AD

- Créer ou choisir un compte de service dédié au service HTTP Keycloak.
- Enregistrer un SPN unique `HTTP/<FQDN-Keycloak>` sur ce compte (vérifier l'absence de doublon avant toute modification).
- Générer un keytab avec les types de chiffrement autorisés par la politique AD (AES, pas de RC4 sauf exception motivée).
- Vérifier le SPN et le contenu du keytab avec les outils AD/Kerberos avant déploiement.
- Maintenir une synchronisation horaire fiable entre K3s, les DC et les postes clients.

Ne jamais placer le keytab dans l'archive, dans un dépôt Git, dans `config.env` ou dans les logs. Il doit être stocké comme Secret Kubernetes à accès limité.

## 3. Montage du keytab dans l'Operator

La documentation Operator décrit `spec.unsupported.podTemplate` comme un mécanisme temporaire, expérimental/Tech Preview. Le montage d'un keytab par ce biais n'est pas inclus dans les scripts d'installation automatique. Il doit être évalué avec la version d'Operator retenue.

Structure indicative à adapter au conteneur généré par l'Operator après inspection du Deployment :

```yaml
spec:
  unsupported:
    podTemplate:
      spec:
        volumes:
          - name: kerberos-keytab
            secret:
              secretName: keycloak-kerberos
              defaultMode: 0440
        containers:
          - name: keycloak
            volumeMounts:
              - name: kerberos-keytab
                mountPath: /opt/keycloak/conf/krb5.keytab
                subPath: krb5.keytab
                readOnly: true
```

Le nom de conteneur, le chemin, le comportement d'UID/GID et les clés Secret doivent être confirmés sur le Deployment réel avant application. Ne pas appliquer cet exemple tel quel sans validation.

Un `krb5.conf` peut aussi être monté comme ConfigMap si la résolution realm/domain ne peut pas être déduite correctement. Les DNS SRV Kerberos/LDAP doivent être accessibles depuis les pods Keycloak.

## 4. Configuration Keycloak

Après exposition du keytab et validation de l'accès DNS/KDC :

1. Dans **User Federation**, configurer le provider LDAP AD.
2. Dans la section Kerberos Integration du provider LDAP, activer **Allow Kerberos authentication**.
3. Définir le chemin keytab, le Kerberos realm et le principal HTTP selon le schéma de la version Keycloak.
4. Dans **Authentication > Flows**, ouvrir le Browser Flow et activer l'exécution Kerberos comme `ALTERNATIVE` pour conserver le repli formulaire, ou `REQUIRED` uniquement si tous les clients sont correctement configurés.
5. Tester avec un compte pilote avant d'étendre le flux.

Par défaut, SPNEGO est désactivé ; il doit être activé dans le Browser Flow. Si le navigateur n'a pas de ticket ou si le site n'est pas en liste de confiance, l'authentification transparente ne se produira pas.

## 5. Navigateurs Windows

Configurer les navigateurs via GPO afin que le FQDN Keycloak soit considéré comme un site Intranet autorisé pour l'authentification intégrée. Vérifier que les navigateurs utilisent le ticket Kerberos et non un fallback NTLM.

## 6. Diagnostic

- Vérifier le DNS A/AAAA et les SRV `_kerberos._tcp` / `_ldap._tcp`.
- Vérifier le SPN depuis AD et détecter les doublons.
- Vérifier la validité du keytab et la correspondance des KVNO/encryption types.
- Vérifier la dérive horaire.
- Activer temporairement les logs Kerberos/SPNEGO ciblés et désactiver le debug après diagnostic.
- Ne pas activer le debug Kerberos permanent : les logs peuvent exposer des informations sensibles.

Références :
- [Keycloak Server Administration – Kerberos](https://www.keycloak.org/docs/26.8.2/server_admin/)
- [Keycloak LDAP / Active Directory](https://www.keycloak.org/docs/26.8.2/server_admin/)
