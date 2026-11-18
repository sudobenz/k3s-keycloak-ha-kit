# Cycle de mise à niveau contrôlé

Tous les scripts sont explicites, version-ciblés et non automatiques. Le mode par défaut est la simulation (aucune modification). Ajouter `--apply` uniquement après revue. Les opérations PostgreSQL/Longhorn/CRD exigent un fichier privé `backup-evidence.env` valide. Ce fichier n’est pas fourni et ne doit jamais être partagé : copier le modèle, le renseigner, tester réellement la restauration et conserver les preuves hors cluster.

Ordre conseillé : `00-inventory.sh`, `01-preflight.sh`, `02-backup-postgres.sh`, création/validation du fichier de preuves, puis une seule procédure `03+` à la fois. Après chaque opération, exécuter `99-postcheck.sh` et ne poursuivre que si tous les contrôles sont verts.

Les versions ne sont jamais découvertes automatiquement à partir de `latest`. Chaque cible est fournie explicitement. Lire les notes de version, la matrice de compatibilité et le chemin de mise à niveau officiel avant `--apply`. Les scripts refusent les mises à niveau majeures non gérées.

`config.env` reste le fichier de verrouillage des versions : chaque script modifie sa variable uniquement après un post-contrôle réussi. Le fichier est sauvegardé sous `upgrade/backups/config.env.*` avant modification.
