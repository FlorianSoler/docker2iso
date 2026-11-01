#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

DOCKERFILE="Containerfile"
ROOTFS="${ROOTFS:-$(pwd)/build/docker-rootfs}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/out}"
FINALIZE="$(pwd)/scripts/finalize-rootfs.sh"
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
#   $1 = cible du Containerfile (live|install)
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
TARGET="$3"
FINALIZE="$4"

tar -xf - -C "$ROOTFS"

# Uniquement les éléments propres au conteneur. Les configurations du dépôt
# sont déjà présentes via les overlays image/ et les COPY du Containerfile.
bash "$FINALIZE" "$ROOTFS" "$TARGET"

echo "==> Compression en SquashFS -> $OUTPUT"
mkdir -p "$(dirname -- "$OUTPUT")"
rm -f "$OUTPUT"
mksquashfs "$ROOTFS" "$OUTPUT" -noappend -comp xz -b 1M
INNER

  docker export "$CONTAINER_ID" | \
    fakeroot -- bash "$inner_script" "$ROOTFS" "$output" "$target" "$FINALIZE"
  rm -f "$inner_script"

  docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  CONTAINER_ID=""
  rm -rf "$ROOTFS"

  echo "SquashFS prêt : $output"
}

# Outils hôte nécessaires
for cmd in docker mksquashfs fakeroot; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Commande requise absente : $cmd" >&2
    exit 1
  }
done

mkdir -p "$OUTPUT_DIR"

# 1. Image live (desktop + casper + installateur)
build_squashfs live liveinstall-live "$OUTPUT_DIR/filesystem.squashfs"

# 2. Image install (desktop propre copié sur le disque)
build_squashfs install liveinstall-install "$OUTPUT_DIR/install.squashfs"

echo
echo "Terminé :"
echo "  $OUTPUT_DIR/filesystem.squashfs  (live)"
echo "  $OUTPUT_DIR/install.squashfs     (système installé)"
