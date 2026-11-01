#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

LIVE_SQUASHFS="${1:-${LIVE_SQUASHFS:-out/filesystem.squashfs}}"
OUTPUT="${2:-${EFI_IMG:-build/iso/efi.img}}"

die() { echo "ERREUR : $*" >&2; exit 1; }

[[ -f "$LIVE_SQUASHFS" ]] || die "SquashFS live introuvable : $LIVE_SQUASHFS"
for cmd in unsquashfs mkfs.fat mmd mcopy; do
  command -v "$cmd" >/dev/null 2>&1 || die "Commande requise absente : $cmd"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/EFI/BOOT" "$TMP/EFI/ubuntu" "$(dirname -- "$OUTPUT")"

extract_efi() {
  local path="$1" dest="$2"
  if ! unsquashfs -cat "$LIVE_SQUASHFS" "$path" >"$dest" 2>/dev/null; then
    die "Fichier introuvable dans $LIVE_SQUASHFS : $path"
  fi
  [[ -s "$dest" ]] || die "Fichier vide dans $LIVE_SQUASHFS : $path"
  [[ "$(head -c 2 "$dest")" == "MZ" ]] || die "Ce n'est pas un binaire EFI : $path"
}

# Shim signé par Microsoft. Le lien .signed est une alternative Debian ;
# .signed.latest est le fichier réel et évite toute ambiguïté.
SHIM_PATH=usr/lib/shim/shimx64.efi.signed.latest
extract_efi "$SHIM_PATH" "$TMP/EFI/BOOT/BOOTX64.EFI"
extract_efi usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$TMP/EFI/BOOT/grubx64.efi"

# Gestion MOK uniquement. Ne pas copier fbx64.efi : shim détecte le
# démarrage depuis le chemin amovible EFI/BOOT et lance alors fbx64.efi,
# qui exige un BOOTX64.CSV et redémarre la machine s'il est absent.
for f in mmx64.efi; do
  if unsquashfs -cat "$LIVE_SQUASHFS" "usr/lib/shim/$f" >"$TMP/EFI/BOOT/$f" 2>/dev/null; then
    [[ -s "$TMP/EFI/BOOT/$f" ]] || rm -f "$TMP/EFI/BOOT/$f"
  else
    rm -f "$TMP/EFI/BOOT/$f"
  fi
done

# Le GRUB signé Canonical a /EFI/ubuntu comme préfixe compilé.
# On recherche le fichier plutôt que le label : le même fichier est copié
# à la racine de l'ISO, car GRUB voit le système ISO9660 et non l'image EFI
# El Torito dans laquelle il a été chargé.
install -m 0644 iso/boot/grub/efi.cfg "$TMP/EFI/ubuntu/grub.cfg"

rm -f "$OUTPUT"
dd if=/dev/zero of="$OUTPUT" bs=1M count=16 status=none
# FAT16 : une image FAT32 de 16 Mo tombe sous le minimum de 65525 clusters
# et certains firmwares la refusent. FAT16 est supporté pour les médias
# amovibles (El Torito) et reste sous la limite de 32 Mo de Ldsiz.
mkfs.fat -F 16 -n EFI "$OUTPUT" >/dev/null
mmd -i "$OUTPUT" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu
mcopy -i "$OUTPUT" "$TMP/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$OUTPUT" "$TMP/EFI/BOOT/grubx64.efi" ::/EFI/BOOT/grubx64.efi
for f in mmx64.efi; do
  [[ -f "$TMP/EFI/BOOT/$f" ]] && mcopy -i "$OUTPUT" "$TMP/EFI/BOOT/$f" "::/EFI/BOOT/$f"
done
mcopy -i "$OUTPUT" "$TMP/EFI/ubuntu/grub.cfg" ::/EFI/ubuntu/grub.cfg

if command -v fsck.fat >/dev/null 2>&1; then
  fsck.fat -n "$OUTPUT" >/dev/null || die "Image FAT invalide : $OUTPUT"
fi

echo "Image EFI signée prête : $OUTPUT"
