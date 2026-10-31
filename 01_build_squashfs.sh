#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")"

IMAGE="ubuntu-26-custom"
ROOTFS="/tmp/docker-rootfs"
CONTAINER_ID=""

cleanup() {
  set +e
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
  if [[ -d "$ROOTFS" ]]; then
    sudo rm -rf "$ROOTFS"
  fi
}
trap cleanup EXIT

# 1. Construire l'image Docker
docker build -f dockerfile -t "$IMAGE" .

# 2. Créer un conteneur temporaire et exporter le système de fichiers
CONTAINER_ID="$(docker create "$IMAGE")"
sudo rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
docker export "$CONTAINER_ID" | sudo tar -xf - -C "$ROOTFS"

# 3. Supprimer les fichiers propres au conteneur
sudo rm -rf "$ROOTFS/.dockerenv"

# 4. Compresser en SquashFS
sudo apt-get update && sudo apt-get install -y squashfs-tools
sudo rm -f ./filesystem.squashfs
sudo mksquashfs "$ROOTFS" ./filesystem.squashfs -noappend -comp xz -b 1M

echo
echo "SquashFS prêt : $(pwd)/filesystem.squashfs"
