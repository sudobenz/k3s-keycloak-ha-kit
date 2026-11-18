
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Préparation du disque Longhorn
# Aucun disque n'est présélectionné.
# Fournir explicitement le chemin /dev/disk/by-id/ propre à chaque hôte.
# ============================================================

DISK_ID=""
PARTITION_ID=""
MOUNTPOINT="/var/lib/longhorn"
LABEL="LONGHORN"

usage() {
    cat <<'EOF'
Usage : prepare-longhorn-disk.sh [options]

Options :
  --disk-id PATH       Disque entier OBLIGATOIRE (de préférence /dev/disk/by-id/...)
  --partition-id PATH  Chemin de la partition 1 ; par défaut DISK_ID-part1
  --mountpoint PATH    Point de montage (défaut : /var/lib/longhorn)
  --label LABEL        Label ext4 (défaut : LONGHORN)
  -h, --help           Afficher cette aide

ATTENTION : le script peut partitionner et formater le disque sélectionné.
Il demande la saisie explicite de FORMAT-LONGHORN avant toute destruction.
EOF
}

while (($#)); do
    case "$1" in
        --disk-id)
            (($# >= 2)) || { echo "Valeur manquante pour --disk-id" >&2; exit 2; }
            DISK_ID="$2"; shift 2 ;;
        --partition-id)
            (($# >= 2)) || { echo "Valeur manquante pour --partition-id" >&2; exit 2; }
            PARTITION_ID="$2"; shift 2 ;;
        --mountpoint)
            (($# >= 2)) || { echo "Valeur manquante pour --mountpoint" >&2; exit 2; }
            MOUNTPOINT="$2"; shift 2 ;;
        --label)
            (($# >= 2)) || { echo "Valeur manquante pour --label" >&2; exit 2; }
            LABEL="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Option inconnue : $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$DISK_ID" ]] || { echo "--disk-id est obligatoire : le script ne devine jamais le disque à formater." >&2; usage >&2; exit 2; }

if [[ -z "$PARTITION_ID" ]]; then
    PARTITION_ID="${DISK_ID}-part1"
fi
[[ "$DISK_ID" == /dev/* && "$PARTITION_ID" == /dev/* ]] || { echo "DISK_ID/PARTITION_ID doivent être des chemins /dev/..." >&2; exit 2; }
[[ "$MOUNTPOINT" == /* && "$MOUNTPOINT" != *[[:space:]]* ]] || { echo "MOUNTPOINT doit être un chemin absolu sans espace." >&2; exit 2; }
[[ "$LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]] || { echo "LABEL ext4 invalide (1-16 caractères alphanumériques, _ ou -)." >&2; exit 2; }

log()  { echo -e "\n[INFO] $*"; }
ok()   { echo -e "[OK] $*"; }
fail() { echo -e "\n[ERREUR] $*" >&2; exit 1; }

# ------------------------------------------------------------
# 1. Verification des prerequis
# ------------------------------------------------------------

[[ $EUID -eq 0 ]] || fail "Lancer ce script en root."

for cmd in lsblk blkid wipefs parted partprobe \
           udevadm mkfs.ext4 findmnt mountpoint; do
    command -v "$cmd" >/dev/null 2>&1 \
        || fail "Commande manquante : $cmd"
done

[[ -L "$DISK_ID" ]] || fail "Disque introuvable : $DISK_ID"

DISK_REAL="$(readlink -f "$DISK_ID")"

[[ -b "$DISK_REAL" ]] || fail "Le chemin ne pointe pas vers un disque."

[[ "$(lsblk -dn -o TYPE "$DISK_REAL")" == "disk" ]] \
    || fail "Le périphérique sélectionné n'est pas un disque."

log "Disque identifie :"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK_REAL"

# ------------------------------------------------------------
# 2. Protection du disque systeme
# ------------------------------------------------------------

ROOT_SOURCE="$(findmnt -n -o SOURCE / | sed 's/\[.*\]$//')"
ROOT_REAL="$(readlink -f "$ROOT_SOURCE" || true)"

if [[ -b "$ROOT_REAL" ]]; then
    if lsblk -s -nrpo NAME "$ROOT_REAL" | grep -Fxq "$DISK_REAL"; then
        fail "Le disque selectionne participe au stockage systeme !"
    fi
fi

# ------------------------------------------------------------
# 3. Verification des montages existants
# ------------------------------------------------------------

while read -r DEVICE; do
    if findmnt -rn -S "$DEVICE" >/dev/null 2>&1; then
        fail "$DEVICE est deja monte. Operation annulee."
    fi
done < <(lsblk -nrpo NAME "$DISK_REAL")

assert_partition_belongs_to_disk() {
    local parent_name parent_real
    [[ -b "$PARTITION_ID" ]] || fail "Partition introuvable : $PARTITION_ID"
    parent_name="$(lsblk -no PKNAME "$PARTITION_ID" | head -n1 | tr -d '[:space:]')"
    [[ -n "$parent_name" ]] || fail "Impossible d'identifier le disque parent de $PARTITION_ID."
    parent_real="$(readlink -f "/dev/$parent_name")"
    [[ "$parent_real" == "$DISK_REAL" ]] \
        || fail "La partition $PARTITION_ID appartient à $parent_real et non au disque sélectionné $DISK_REAL."
}

# ------------------------------------------------------------
# 4. Confirmation obligatoire
# ------------------------------------------------------------

echo
echo "============================================================"
echo " ATTENTION : FORMATAGE DU DISQUE"
echo "============================================================"
echo "Identifiant : $DISK_ID"
echo "Peripherique : $DISK_REAL"
echo "Montage : $MOUNTPOINT"
echo "Format : GPT + ext4"
echo
echo "Toutes les donnees presentes sur ce disque seront effacees."
echo

read -r -p "Pour confirmer, saisir FORMAT-LONGHORN : " CONFIRM

[[ "$CONFIRM" == "FORMAT-LONGHORN" ]] \
    || fail "Confirmation incorrecte."

# ------------------------------------------------------------
# 5. Partitionnement
# ------------------------------------------------------------

if [[ -b "$PARTITION_ID" ]]; then
    assert_partition_belongs_to_disk
    log "Une partition existe deja. Verification."

    CHILD_COUNT="$(lsblk -nrpo NAME "$DISK_REAL" | tail -n +2 | wc -l)"

    [[ "$CHILD_COUNT" -eq 1 ]] \
        || fail "Plusieurs partitions detectees. Intervention manuelle requise."

    FSTYPE="$(blkid -s TYPE -o value "$PARTITION_ID" 2>/dev/null || true)"
    CURRENT_LABEL="$(blkid -s LABEL -o value "$PARTITION_ID" 2>/dev/null || true)"

    if [[ "$FSTYPE" == "ext4" && "$CURRENT_LABEL" == "$LABEL" ]]; then
        log "Partition LONGHORN ext4 deja presente : conservation."
    elif [[ -z "$FSTYPE" ]]; then
        log "Partition vide detectee : formatage possible."
        mkfs.ext4 -F -L "$LABEL" "$PARTITION_ID"
    else
        fail "Partition existante avec un format inattendu : $FSTYPE / $CURRENT_LABEL"
    fi

else
    log "Creation de la table GPT et de la partition."

    CHILD_COUNT="$(lsblk -nrpo NAME "$DISK_REAL" | tail -n +2 | wc -l)"

    [[ "$CHILD_COUNT" -eq 0 ]] \
        || fail "Des partitions existent deja sur ce disque."

    EXISTING_SIGNATURES="$(wipefs -n "$DISK_REAL" 2>/dev/null || true)"

    [[ -z "$EXISTING_SIGNATURES" ]] \
        || fail "Des signatures existantes ont ete detectees. Verification manuelle necessaire."

    parted -s "$DISK_REAL" mklabel gpt
    parted -s "$DISK_REAL" mkpart primary ext4 1MiB 100%

    partprobe "$DISK_REAL"
    udevadm settle

    for i in {1..10}; do
        [[ -b "$PARTITION_ID" ]] && break
        sleep 1
        udevadm settle
    done

    [[ -b "$PARTITION_ID" ]] \
        || fail "Partition non detectee apres partitionnement."
    assert_partition_belongs_to_disk

    mkfs.ext4 -F -L "$LABEL" "$PARTITION_ID"
fi

# ------------------------------------------------------------
# 6. Recuperation UUID
# ------------------------------------------------------------

UUID="$(blkid -s UUID -o value "$PARTITION_ID")"

[[ -n "$UUID" ]] || fail "Impossible de recuperer l'UUID."

log "UUID : $UUID"

# ------------------------------------------------------------
# 7. Configuration du montage
# ------------------------------------------------------------

mkdir -p "$MOUNTPOINT"

if mountpoint -q "$MOUNTPOINT"; then
    fail "$MOUNTPOINT est deja un point de montage."
fi

if find "$MOUNTPOINT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    fail "$MOUNTPOINT n'est pas vide. Verification necessaire."
fi

FSTAB_LINE="UUID=${UUID} ${MOUNTPOINT} ext4 defaults,noatime 0 2"

if awk -v mp="$MOUNTPOINT" \
    '$1 !~ /^#/ && $2 == mp {found=1} END {exit !found}' /etc/fstab; then

    if ! awk -v uuid="UUID=${UUID}" -v mp="$MOUNTPOINT" \
        '$1 == uuid && $2 == mp && $3 == "ext4" {found=1} END {exit !found}' /etc/fstab; then
        fail "Une entree /etc/fstab incompatible existe deja."
    fi

    log "Entree fstab deja presente."

else
    echo "$FSTAB_LINE" >> /etc/fstab
    ok "Entree /etc/fstab ajoutee."
fi

# ------------------------------------------------------------
# 8. Montage
# ------------------------------------------------------------

systemctl daemon-reload
mount "$MOUNTPOINT"

# ------------------------------------------------------------
# 9. Verification finale
# ------------------------------------------------------------

[[ "$(findmnt -n -o FSTYPE --target "$MOUNTPOINT")" == "ext4" ]] \
    || fail "Le systeme de fichiers monte n'est pas ext4."

MOUNT_SOURCE="$(findmnt -n -o SOURCE --target "$MOUNTPOINT")"

[[ "$(readlink -f "$MOUNT_SOURCE")" == "$(readlink -f "$PARTITION_ID")" ]] \
    || fail "Le montage ne correspond pas a la partition attendue."

echo
echo "============================================================"
echo " PREPARATION LONGHORN TERMINEE"
echo "============================================================"

lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DISK_REAL"
df -hT "$MOUNTPOINT"

ok "Disque pret pour Longhorn."
