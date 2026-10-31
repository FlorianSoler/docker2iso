#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_MOUNT="/mnt/target"
SQUASH_MOUNT="/mnt/squash"
BOOT_ID="GRUB"

die() { echo "ERREUR : $*" >&2; exit 1; }
log() { echo; echo "--> $*"; }

if (( EUID != 0 )); then
  die "Lancez ce script en root : sudo env TARGET_DISK=/dev/sda ./02_vm_install.sh"
fi

for cmd in lsblk findmnt parted partprobe udevadm mkfs.fat mkfs.ext4 blkid mount umount rsync chroot wipefs; do
  command -v "$cmd" >/dev/null 2>&1 || die "Commande requise absente : $cmd"
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Détection du disque cible
DISK="${TARGET_DISK:-}"
if [[ -n "$DISK" ]]; then
  [[ -b "$DISK" ]] || die "TARGET_DISK n'est pas un périphérique bloc : $DISK"
else
  CANDIDATES=()
  for d in /dev/vda /dev/sda /dev/nvme0n1 /dev/xvda; do
    [[ -b "$d" ]] || continue
    [[ "$(lsblk -dnro TYPE "$d" 2>/dev/null || true)" == "disk" ]] || continue
    CANDIDATES+=("$d")
  done
  if (( ${#CANDIDATES[@]} == 1 )); then
    DISK="${CANDIDATES[0]}"
  else
    lsblk -dpno NAME,SIZE,MODEL,TYPE
    die "Détection ambiguë. Relancez avec TARGET_DISK=/dev/LE_DISQUE."
  fi
fi

# Localiser le filesystem.squashfs
if [[ -z "${SQUASHFS_PATH:-}" ]]; then
  for candidate in \
    "$SCRIPT_DIR/filesystem.squashfs" \
    /cdrom/casper/filesystem.squashfs \
    /casper/filesystem.squashfs; do
    if [[ -f "$candidate" ]]; then
      SQUASHFS_PATH="$candidate"
      break
    fi
  done
fi
if [[ -z "${SQUASHFS_PATH:-}" ]]; then
  SQUASHFS_PATH="$(find /media /mnt /run/media -maxdepth 4 -type f -name filesystem.squashfs 2>/dev/null | head -n1 || true)"
fi
[[ -n "${SQUASHFS_PATH:-}" && -f "$SQUASHFS_PATH" ]] || die "Impossible de trouver filesystem.squashfs. Indiquez son chemin avec SQUASHFS_PATH=/chemin/vers/filesystem.squashfs."
SQUASHFS_PATH="$(readlink -f "$SQUASHFS_PATH")"

echo "Disque cible : $DISK"
read -r -p "Pour confirmer la destruction des données sur $DISK, tapez 'DETRUIRE $DISK' : " CONFIRM
[[ "$CONFIRM" == "DETRUIRE $DISK" ]] || die "Confirmation incorrecte, arrêt."

if [[ "$DISK" =~ (nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$ ]]; then
  P1="${DISK}p1"
  P2="${DISK}p2"
else
  P1="${DISK}1"
  P2="${DISK}2"
fi

cleanup() {
  set +e
  sync
  umount -R "$TARGET_MOUNT/dev" "$TARGET_MOUNT/proc" "$TARGET_MOUNT/sys" "$TARGET_MOUNT/run" 2>/dev/null || true
  umount "$TARGET_MOUNT/boot/efi" "$TARGET_MOUNT" "$SQUASH_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$TARGET_MOUNT" "$SQUASH_MOUNT"

log "Partitionnement GPT et formatage de $DISK"
wipefs -a "$DISK" || true
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart EFI fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart root ext4 513MiB 100%
partprobe "$DISK" || true
udevadm settle

for _ in {1..10}; do
  [[ -b "$P1" && -b "$P2" ]] && break
  sleep 1
done
[[ -b "$P1" && -b "$P2" ]] || die "Les partitions n'apparaissent pas."

mkfs.fat -F 32 -n EFI "$P1"
mkfs.ext4 -F -L ubuntu-root "$P2"

log "Montage et copie du SquashFS"
mount "$P2" "$TARGET_MOUNT"
mkdir -p "$TARGET_MOUNT/boot/efi"
mount "$P1" "$TARGET_MOUNT/boot/efi"

mount -t squashfs -o loop,ro "$SQUASHFS_PATH" "$SQUASH_MOUNT"
rsync -aHAX --numeric-ids --info=progress2 "$SQUASH_MOUNT/" "$TARGET_MOUNT/"

log "Écriture de /etc/fstab"
UUID_ROOT="$(blkid -s UUID -o value "$P2")"
UUID_EFI="$(blkid -s UUID -o value "$P1")"
cat > "$TARGET_MOUNT/etc/fstab" <<FSTAB
UUID=$UUID_ROOT / ext4 errors=remount-ro 0 1
UUID=$UUID_EFI /boot/efi vfat umask=0077 0 1
FSTAB

log "Préparation du chroot et installation de GRUB"
for d in dev dev/pts proc sys run; do mkdir -p "$TARGET_MOUNT/$d"; done
mount --rbind /dev "$TARGET_MOUNT/dev" && mount --make-rslave "$TARGET_MOUNT/dev"
mount --rbind /proc "$TARGET_MOUNT/proc" && mount --make-rslave "$TARGET_MOUNT/proc"
mount --rbind /sys "$TARGET_MOUNT/sys" && mount --make-rslave "$TARGET_MOUNT/sys"
mount --rbind /run "$TARGET_MOUNT/run" && mount --make-rslave "$TARGET_MOUNT/run"

chroot "$TARGET_MOUNT" /bin/bash -s "$BOOT_ID" <<'CHROOT'
BOOT_ID="$1"
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

grub-install \
  --efi-directory=/boot/efi \
  --bootloader-id="$BOOT_ID"

update-grub
CHROOT

sync
log "Installation terminée avec succès !"
