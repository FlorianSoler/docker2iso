#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")"

DOCKERFILE="dockerfile"
ROOTFS="${ROOTFS:-$(pwd)/build/docker-rootfs}"
CONTAINER_ID=""

cleanup() {
  set +e
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
    CONTAINER_ID=""
  fi
  rm -f "${ROOTFS}.fakeroot.sh"
  if [[ -d "$ROOTFS" ]]; then
    rm -rf "$ROOTFS"
  fi
}
trap cleanup EXIT

# Build d'une cible Docker, export du rootfs puis compression en SquashFS.
#   $1 = cible du Dockerfile (live|install)
#   $2 = nom de l'image Docker
#   $3 = fichier SquashFS de sortie
build_squashfs() {
  local target="$1"
  local image="$2"
  local output="$3"
  local inner_script="${ROOTFS}.fakeroot.sh"

  echo
  echo "==> Build de l'image '$image' (cible : $target)"
  docker build -f "$DOCKERFILE" --target "$target" -t "$image" .

  echo "==> Export du système de fichiers"
  CONTAINER_ID="$(docker create "$image")"
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"

  # fakeroot évite d'avoir besoin de sudo pour préserver les propriétaires
  # (root, monuser, gdm, ...) dans le SquashFS.
  cat > "$inner_script" <<'INNER'
set -Eeuo pipefail
ROOTFS="$1"
OUTPUT="$2"

tar -xf - -C "$ROOTFS"

# Fichiers propres au conteneur
rm -rf "$ROOTFS/.dockerenv"

# Certains postinst réécrivent ces fichiers pendant le build Docker.
install -D -m 0644 config/keyboard "$ROOTFS/etc/default/keyboard"
install -D -m 0644 config/grub "$ROOTFS/etc/default/grub"

# Docker export laisse ces fichiers vides (ou liés au conteneur).
# Sans eux, GDM/GNOME et systemd-resolved peuvent mal démarrer.
printf 'liveinstall\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 liveinstall
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
rm -f "$ROOTFS/etc/resolv.conf"
ln -sfn /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

# Un machine-id unique sera généré au premier démarrage (live et installé).
rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id"
mkdir -p "$ROOTFS/var/lib/dbus"
ln -sfn /etc/machine-id "$ROOTFS/var/lib/dbus/machine-id"

# Les fichiers recréés ci-dessus doivent appartenir à root dans le SquashFS.
chown 0:0 "$ROOTFS" "$ROOTFS/var/lib/dbus"
chown 0:0 "$ROOTFS/etc/hostname" "$ROOTFS/etc/hosts"
chown 0:0 "$ROOTFS/etc/default/keyboard" "$ROOTFS/etc/default/grub"
chown -h 0:0 "$ROOTFS/etc/resolv.conf" "$ROOTFS/var/lib/dbus/machine-id"

echo "==> Compression en SquashFS -> $OUTPUT"
rm -f "./$OUTPUT"
mksquashfs "$ROOTFS" "./$OUTPUT" -noappend -comp xz -b 1M
INNER

  docker export "$CONTAINER_ID" | fakeroot -- bash "$inner_script" "$ROOTFS" "$output"
  rm -f "$inner_script"

  docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  CONTAINER_ID=""
  rm -rf "$ROOTFS"

  echo "SquashFS prêt : $(pwd)/$output"
}

# Outils hôte nécessaires
for cmd in docker mksquashfs fakeroot; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Commande requise absente : $cmd" >&2
    exit 1
  }
done

# 1. Image live (desktop + casper + installateur)
build_squashfs live liveinstall-live filesystem.squashfs

# 2. Image install (desktop propre copié sur le disque)
build_squashfs install liveinstall-install install.squashfs

echo
echo "Terminé :"
echo "  $(pwd)/filesystem.squashfs  (live)"
echo "  $(pwd)/install.squashfs     (système installé)"
