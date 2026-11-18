# Contribuer

Avant de proposer une modification :

1. Ne commitez aucun fichier `config.env`, `secrets.env`, kubeconfig, certificat, keytab, export ou manifeste généré contenant des données locales.
2. Conservez les valeurs d’exemple sous forme de placeholders ou d’adresses réservées à la documentation.
3. Vérifiez la syntaxe des scripts Bash avec `bash -n` et des scripts Python avec `python3 -m py_compile`.
4. Documentez les prérequis, les effets de bord et les opérations destructives.
5. Distinguez clairement les vérifications statiques des essais réellement effectués sur un cluster.

Toute modification des procédures de bootstrap, de stockage, de sécurité ou de mise à niveau doit préciser les conditions de retour arrière et les contrôles post-opération.
