#!/usr/bin/env bash
# Extend the existing partition/filesystem on the explicitly selected disk after the virtual disk
# has already been enlarged in the hypervisor.
# Default: dry-run. Execute changes only with --apply.
set -Eeuo pipefail

DISK=""
MODE="dry-run"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash extend-longhorn-disk.sh --disk /dev/disk/by-id/<ID>
  sudo bash extend-longhorn-disk.sh --disk /dev/disk/by-id/<ID> --apply

IMPORTANT:
  Increase the virtual disk size in the hypervisor before running --apply.
  This script deliberately refuses ambiguous layouts, multiple partitions,
  LVM physical volumes, and unknown filesystems.
USAGE
}

while (($#)); do
  case "$1" in
    --disk) (($# >= 2)) || { usage >&2; exit 2; }; DISK="$2"; shift 2 ;;
    --apply) MODE="apply"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$DISK" ]] || { echo "--disk est obligatoire : aucun disque par défaut ne sera supposé." >&2; usage >&2; exit 2; }

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERREUR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Exécuter en root : sudo bash $0 --disk <disk> [--apply]"
[[ -b "$DISK" ]] || die "$DISK absent ou n'est pas un périphérique bloc."

for cmd in lsblk blockdev findmnt blkid; do
  command -v "$cmd" >/dev/null 2>&1 || die "Commande requise introuvable : $cmd"
done

log "Hôte : $(hostname -f 2>/dev/null || hostname)"
log "Mode : $MODE"
if [[ "$MODE" == "apply" ]]; then
  RESCAN="/sys/class/block/${DISK##*/}/device/rescan"
  if [[ -w "$RESCAN" ]]; then
    log "Demande de re-détection de la capacité de $DISK par le noyau..."
    printf '1' > "$RESCAN"
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 2
  else
    log "AVERTISSEMENT : mécanisme SCSI rescan indisponible pour $DISK. La capacité visible par Linux sera utilisée telle quelle."
  fi
fi

log "État actuel de $DISK :"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$DISK"

mapfile -t PARTS < <(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2 == "part" {print $1}')

if ((${#PARTS[@]} > 1)); then
  die "$DISK contient plusieurs partitions (${PARTS[*]}). Arrêt par sécurité : identifier la partition Longhorn avant toute modification."
fi

if ((${#PARTS[@]} == 1)); then
  TARGET="${PARTS[0]}"
  PARTNUM="$(lsblk -no PARTN "$TARGET" | xargs)"
  [[ -n "$PARTNUM" ]] || die "Impossible de déterminer le numéro de partition de $TARGET."
  FSTYPE="$(blkid -o value -s TYPE "$TARGET" 2>/dev/null || true)"
  ACTION="partition $PARTNUM de $DISK, puis système de fichiers sur $TARGET"
  command -v growpart >/dev/null 2>&1 || die "growpart absent. Sur Debian/Ubuntu : apt-get update && apt-get install -y cloud-guest-utils"
else
  TARGET="$DISK"
  FSTYPE="$(blkid -o value -s TYPE "$TARGET" 2>/dev/null || true)"
  ACTION="système de fichiers directement sur $DISK (aucune partition détectée)"
fi

case "$FSTYPE" in
  ext2|ext3|ext4)
    RESIZE_CMD="resize2fs $TARGET"
    command -v resize2fs >/dev/null 2>&1 || die "resize2fs absent (paquet e2fsprogs)."
    ;;
  xfs)
    MOUNTPOINT="$(findmnt -rn -S "$TARGET" -o TARGET | head -n1 || true)"
    [[ -n "$MOUNTPOINT" ]] || die "Le système XFS $TARGET n'est pas monté ; impossible de déterminer le point de montage."
    RESIZE_CMD="xfs_growfs $MOUNTPOINT"
    command -v xfs_growfs >/dev/null 2>&1 || die "xfs_growfs absent (paquet xfsprogs)."
    ;;
  btrfs)
    MOUNTPOINT="$(findmnt -rn -S "$TARGET" -o TARGET | head -n1 || true)"
    [[ -n "$MOUNTPOINT" ]] || die "Le système Btrfs $TARGET n'est pas monté."
    RESIZE_CMD="btrfs filesystem resize max $MOUNTPOINT"
    command -v btrfs >/dev/null 2>&1 || die "Commande btrfs absente (paquet btrfs-progs)."
    ;;
  LVM2_member)
    die "$TARGET est un volume physique LVM. Ce script ne modifie pas LVM ; il faut traiter pvresize/lvextend séparément."
    ;;
  "")
    die "Aucun système de fichiers détecté sur $TARGET. Le disque est peut-être brut ou utilisé autrement par Longhorn ; aucune initialisation/formatage ne sera faite."
    ;;
  *)
    die "Système de fichiers non pris en charge : $FSTYPE. Aucune modification effectuée."
    ;;
esac

DISK_BYTES="$(blockdev --getsize64 "$DISK")"
TARGET_BYTES="$(blockdev --getsize64 "$TARGET")"

log "Cible détectée : $ACTION"
log "Système de fichiers : $FSTYPE"
log "Taille disque : $DISK_BYTES octets"
log "Taille cible : $TARGET_BYTES octets"

if [[ "$TARGET" == "$DISK" ]]; then
  log "Aucune partition à agrandir ; seule l'extension du système de fichiers sera tentée."
else
  if (( DISK_BYTES <= TARGET_BYTES + 1048576 )); then
    die "Aucun espace supplémentaire significatif visible après la partition. Vérifier que le disque a bien été agrandi dans l'hyperviseur et que Linux voit la nouvelle taille."
  fi
fi

if [[ "$MODE" == "dry-run" ]]; then
  log "SIMULATION uniquement : aucune modification effectuée."
  if [[ "$TARGET" != "$DISK" ]]; then
    printf 'Commande prévue : growpart %q %q\n' "$DISK" "$PARTNUM"
  fi
  printf 'Commande prévue : %s\n' "$RESIZE_CMD"
  log "Pour appliquer : sudo bash $0 --apply"
  exit 0
fi

if [[ "$TARGET" != "$DISK" ]]; then
  command -v partprobe >/dev/null 2>&1 || die "partprobe absent (paquet parted)."
  command -v udevadm >/dev/null 2>&1 || die "udevadm absent."
  log "Extension de la partition $TARGET..."
  growpart "$DISK" "$PARTNUM"
  log "Relecture de la table des partitions..."
  partprobe "$DISK"
  udevadm settle
  sleep 2
fi

log "Extension du système de fichiers $FSTYPE..."
case "$FSTYPE" in
  ext2|ext3|ext4) resize2fs "$TARGET" ;;
  xfs) xfs_growfs "$MOUNTPOINT" ;;
  btrfs) btrfs filesystem resize max "$MOUNTPOINT" ;;
esac

log "Résultat après extension :"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
df -hT 2>/dev/null || true
log "Opération terminée sur $(hostname -f 2>/dev/null || hostname)."
