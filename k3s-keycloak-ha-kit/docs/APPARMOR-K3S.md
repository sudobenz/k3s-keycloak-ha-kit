# AppArmor – traitement optionnel sur les nœuds K3s

Le kit inclut `scripts/fix-k3s-apparmor-stacked-peer.sh`, issu du retour d'expérience du cluster K3s sous Ubuntu 26.04. Il corrige un cas précis du profil containerd `cri-containerd.apparmor.d` lorsque le noyau empile le peer `//&unconfined` avec `kernel.apparmor_restrict_unprivileged_unconfined=1`.

**Ne pas lancer systématiquement.** Utiliser ce correctif seulement si les diagnostics AppArmor/containerd montrent cette erreur sur un nœud concerné.

Le script :

- exige Ubuntu 26.04 et un service K3s déjà actif ;
- sauvegarde le profil existant ;
- valide la syntaxe avant chargement ;
- charge le profil AppArmor et le vérifie en mode `enforce` ;
- garantit le chargement AppArmor avant K3s via systemd ;
- maintient le durcissement `kernel.apparmor_restrict_unprivileged_unconfined=1` ;
- ne redémarre pas K3s automatiquement.

Le code porte une qualification historique sur K3s 1.36.5 / containerd 2.3.4. Le kit épingle K3s 1.36.6 ; si le correctif s'avère nécessaire sur cette version, vérifier les événements AppArmor et effectuer le test fonctionnel décrit à la fin du script avant de considérer le sujet clos. Le script n'est pas une garantie générique pour toutes les versions/distributions.
