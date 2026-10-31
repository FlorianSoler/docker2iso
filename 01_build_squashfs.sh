#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")"

DOCKERFILE="dockerfile"
ROOTFS="/tmp/docker-rootfs"
CONTAINER_ID=""

cleanup() {
  set +e
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
    CONTAINER_ID=""
  fi
  if [[ -d "$ROOTFS" ]]; then
    sudo rm -rf "$ROOTFS"
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

  echo
  echo "==> Build de l'image '$image' (cible : $target)"
  docker build -f "$DOCKERFILE" --target "$target" -t "$image" .

  echo "==> Export du système de fichiers"
  CONTAINER_ID="$(docker create "$image")"
  sudo rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"
  docker export "$CONTAINER_ID" | sudo tar -xf - -C "$ROOTFS"

  # Fichiers propres au conteneur
  sudo rm -rf "$ROOTFS/.dockerenv"

  echo "==> Compression en SquashFS -> $output"
  sudo rm -f "./$output"
  sudo mksquashfs "$ROOTFS" "./$output" -noappend -comp xz -b 1M

  docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  CONTAINER_ID=""
  sudo rm -rf "$ROOTFS"

  echo "SquashFS prêt : $(pwd)/$output"
}

# Outils hôte nécessaires
if ! command -v mksquashfs >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y squashfs-tools
fi

# 1. Image live (desktop + casper + installateur)
build_squashfs live liveinstall-live filesystem.squashfs

# 2. Image install (desktop propre copié sur le disque)
build_squashfs install liveinstall-install install.squashfs

echo
echo "Terminé :"
echo "  $(pwd)/filesystem.squashfs  (live)"
echo "  $(pwd)/install.squashfs     (système installé)"
