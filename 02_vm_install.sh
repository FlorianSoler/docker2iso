#!/usr/bin/env bash
set -Eeuo pipefail

# Installation d'un système Ubuntu/Debian depuis filesystem.squashfs.
# ATTENTION : le disque cible est entièrement repartitionné et formaté.
# Exemple : sudo env TARGET_DISK=/dev/sda ./02_vm_install.sh
# sudo grub-install --efi-directory=/boot/efi --bootloader-id=GRUB
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

# Détecter le disque cible. En cas d'ambiguïté, exiger TARGET_DISK.
DISK="${TARGET_DISK:-}"
if [[ -n "$DISK" ]]; then
  [[ -b "$DISK" ]] || die "TARGET_DISK n'est pas un périphérique bloc : $DISK"
else
  ROOT_SRC="$(findmnt -nro SOURCE / 2>/dev/null || true)"
  ROOT_REAL="$(readlink -f "${ROOT_SRC%%\[*}" 2>/dev/null || true)"
  CANDIDATES=()

  for d in /dev/vda /dev/sda /dev/nvme0n1 /dev/xvda; do
    [[ -b "$d" ]] || continue
    [[ "$(lsblk -dnro TYPE "$d" 2>/dev/null || true)" == "disk" ]] || continue
    D_REAL="$(readlink -f "$d" 2>/dev/null || true)"
    [[ -n "$ROOT_REAL" && "$ROOT_REAL" == "$D_REAL"* ]] && continue
    CANDIDATES+=("$d")
  done

  if (( ${#CANDIDATES[@]} == 1 )); then
    DISK="${CANDIDATES[0]}"
  else
    echo "Disques détectés possibles :"
    lsblk -dpno NAME,SIZE,MODEL,TYPE
    die "Détection ambiguë. Relancez avec TARGET_DISK=/dev/LE_DISQUE."
  fi
fi

[[ "$(lsblk -dnro TYPE "$DISK" 2>/dev/null)" == "disk" ]] ||
  die "$DISK n'est pas un disque entier."

# Refuser le disque qui contient la racine du système actuellement démarré.
ROOT_SRC="$(findmnt -nro SOURCE / 2>/dev/null || true)"
ROOT_REAL="$(readlink -f "${ROOT_SRC%%\[*}" 2>/dev/null || true)"
DISK_REAL="$(readlink -f "$DISK" 2>/dev/null || true)"
if [[ -n "$ROOT_REAL" && "$ROOT_REAL" == "$DISK_REAL"* ]]; then
  die "$DISK semble contenir le système actuellement démarré ($ROOT_SRC). Refus de continuer."
fi

# Trouver l'image SquashFS.
SQUASHFS_PATH="${SQUASHFS_PATH:-}"
if [[ -z "$SQUASHFS_PATH" ]]; then
  for candidate in "$PWD/filesystem.squashfs" "$SCRIPT_DIR/filesystem.squashfs"; do
    if [[ -f "$candidate" ]]; then SQUASHFS_PATH="$candidate"; break; fi
  done
fi
if [[ -z "$SQUASHFS_PATH" || ! -f "$SQUASHFS_PATH" ]]; then
  SQUASHFS_PATH="$(find "$SCRIPT_DIR" -type f -name filesystem.squashfs -print -quit 2>/dev/null || true)"
fi
[[ -n "$SQUASHFS_PATH" && -f "$SQUASHFS_PATH" ]] ||
  die "Impossible de trouver filesystem.squashfs."
SQUASHFS_PATH="$(readlink -f "$SQUASHFS_PATH")"

command -v unsquashfs >/dev/null 2>&1 || die "Installez squashfs-tools (commande unsquashfs requise)."
unsquashfs -s "$SQUASHFS_PATH" >/dev/null 2>&1 ||
  die "Le fichier ne semble pas être une image SquashFS valide."

echo "Disque cible : $DISK"
echo "Image source : $SQUASHFS_PATH"
lsblk -dpno NAME,SIZE,MODEL "$DISK"
echo
echo "ATTENTION : TOUTES LES DONNÉES SUR $DISK SERONT DÉTRUITES."
read -r -p "Pour confirmer, tapez exactement : DETRUIRE $DISK : " CONFIRM
[[ "$CONFIRM" == "DETRUIRE $DISK" ]] || die "Confirmation incorrecte, arrêt."

# Refuser les montages existants sur le disque cible.
while read -r node; do
  [[ -n "$node" ]] || continue
  if findmnt -rn -S "$node" >/dev/null 2>&1; then
    findmnt -rn -S "$node" >&2 || true
    die "$node est monté. Démontez ses partitions avant de relancer."
  fi
done < <(lsblk -lnpo NAME "$DISK")

# Déterminer les noms de partitions (SCSI/virtio vs NVMe/MMC).
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
  for p in "$TARGET_MOUNT/dev/pts" "$TARGET_MOUNT/dev" "$TARGET_MOUNT/proc" "$TARGET_MOUNT/sys" "$TARGET_MOUNT/run"; do
    mountpoint -q "$p" && umount -R "$p"
  done
  mountpoint -q "$TARGET_MOUNT/boot/efi" && umount "$TARGET_MOUNT/boot/efi"
  mountpoint -q "$TARGET_MOUNT" && umount "$TARGET_MOUNT"
  mountpoint -q "$SQUASH_MOUNT" && umount "$SQUASH_MOUNT"
}
trap cleanup EXIT

mkdir -p "$TARGET_MOUNT" "$SQUASH_MOUNT"
for p in "$TARGET_MOUNT/dev/pts" "$TARGET_MOUNT/dev" "$TARGET_MOUNT/proc" "$TARGET_MOUNT/sys" "$TARGET_MOUNT/run" "$TARGET_MOUNT/boot/efi" "$TARGET_MOUNT" "$SQUASH_MOUNT"; do
  mountpoint -q "$p" && umount -R "$p" || true
done

log "Nettoyage des signatures et partitionnement GPT de $DISK"
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
[[ -b "$P1" && -b "$P2" ]] || die "Les partitions $P1 et/ou $P2 n'apparaissent pas."

log "Formatage des partitions"
mkfs.fat -F 32 -n EFI "$P1"
mkfs.ext4 -F -L ubuntu-root "$P2"

log "Montage des partitions"
mount "$P2" "$TARGET_MOUNT"
mkdir -p "$TARGET_MOUNT/boot/efi"
mount "$P1" "$TARGET_MOUNT/boot/efi"

log "Montage et copie du système SquashFS"
mount -t squashfs -o loop,ro "$SQUASHFS_PATH" "$SQUASH_MOUNT"
rsync -aHAX --numeric-ids --info=progress2 "$SQUASH_MOUNT/" "$TARGET_MOUNT/"

[[ -x "$TARGET_MOUNT/bin/bash" || -x "$TARGET_MOUNT/usr/bin/bash" ]] ||
  die "L'image copiée ne contient pas de bash exécutable."
[[ -d "$TARGET_MOUNT/etc" && -d "$TARGET_MOUNT/usr" ]] ||
  die "L'image copiée ne ressemble pas à un système Linux complet."
[[ -d "$TARGET_MOUNT/boot" ]] || mkdir -p "$TARGET_MOUNT/boot"

log "Écriture de /etc/fstab"
UUID_ROOT="$(blkid -s UUID -o value "$P2")"
UUID_EFI="$(blkid -s UUID -o value "$P1")"
[[ -n "$UUID_ROOT" && -n "$UUID_EFI" ]] || die "Impossible de lire les UUID."
cat > "$TARGET_MOUNT/etc/fstab" <<FSTAB
# /etc/fstab généré par 02_vm_install.sh
UUID=$UUID_ROOT / ext4 errors=remount-ro 0 1
UUID=$UUID_EFI /boot/efi vfat umask=0077 0 1
FSTAB

log "Préparation du chroot"
for d in dev dev/pts proc sys run; do mkdir -p "$TARGET_MOUNT/$d"; done
mount --rbind /dev "$TARGET_MOUNT/dev"
mount --make-rslave "$TARGET_MOUNT/dev"
mount --rbind /proc "$TARGET_MOUNT/proc"
mount --make-rslave "$TARGET_MOUNT/proc"
mount --rbind /sys "$TARGET_MOUNT/sys"
mount --make-rslave "$TARGET_MOUNT/sys"
mount --rbind /run "$TARGET_MOUNT/run"
mount --make-rslave "$TARGET_MOUNT/run"

[[ -f "$TARGET_MOUNT/etc/os-release" ]] || die "Le système copié n'a pas /etc/os-release."
[[ -f "$TARGET_MOUNT/etc/default/grub" ]] || die "Fichier /etc/default/grub absent dans l'image."
[[ -x "$TARGET_MOUNT/usr/sbin/grub-install" || -x "$TARGET_MOUNT/sbin/grub-install" ]] ||
  die "grub-install absent du système copié."
[[ -x "$TARGET_MOUNT/usr/sbin/update-grub" || -x "$TARGET_MOUNT/sbin/update-grub" ]] ||
  die "update-grub absent du système copié."

log "Configuration du clavier et de GRUB"
chroot "$TARGET_MOUNT" /bin/bash -s "$BOOT_ID" <<'CHROOT'
BOOT_ID="$1"
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ -d /etc/default ]]; then
  touch /etc/default/keyboard
  cat > /etc/default/keyboard <<'KEYBOARD'
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT=""
XKBOPTIONS=""
BACKEND="console-setup"
KEYBOARD
fi

python3 - <<'PY'
from pathlib import Path
p = Path("/etc/default/grub")
text = p.read_text() if p.exists() else ""
settings = {
    "GRUB_DEFAULT": "0",
    "GRUB_TIMEOUT": "5",
    "GRUB_TIMEOUT_STYLE": "menu",
    "GRUB_DISABLE_LINUX_UUID": "false",
}
lines = text.splitlines()
for key, value in settings.items():
    prefix = key + "="
    indexes = [i for i, line in enumerate(lines) if line.strip().startswith(prefix) or line.strip().startswith("#" + prefix)]
    new_line = f'{key}="{value}"'
    if indexes:
        lines[indexes[0]] = new_line
        for i in reversed(indexes[1:]):
            del lines[i]
    else:
        lines.append(new_line)
p.write_text("\n".join(lines) + "\n")
PY

grub-install \
  --efi-directory=/boot/efi \
  --bootloader-id="$BOOT_ID" \
  --recheck \
  --removable

update-grub

if ! compgen -G '/boot/vmlinuz-*' >/dev/null; then
  echo "ERREUR : aucun noyau /boot/vmlinuz-* trouvé dans l'image." >&2
  exit 1
fi
if ! compgen -G '/boot/initrd.img-*' >/dev/null && ! compgen -G '/boot/initramfs-*' >/dev/null; then
  echo "ERREUR : aucun initramfs trouvé dans /boot." >&2
  exit 1
fi
test -s /boot/grub/grub.cfg
CHROOT

log "Vérifications finales"
[[ -s "$TARGET_MOUNT/boot/grub/grub.cfg" ]] || die "/boot/grub/grub.cfg absent ou vide."
[[ -s "$TARGET_MOUNT/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] ||
  die "Le chargeur EFI de secours EFI/BOOT/BOOTX64.EFI est absent."

sync
echo
echo "Installation terminée avec succès."
echo "Disque : $DISK"
echo "Racine : $P2 (UUID=$UUID_ROOT)"
echo "EFI    : $P1 (UUID=$UUID_EFI)"
echo
echo "Vous pouvez maintenant éteindre la machine, retirer l'ISO et démarrer."