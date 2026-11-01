#!/usr/bin/env bash
# Nettoyage des éléments propres au conteneur, après `docker export`.
# Ce script ne copie aucune configuration du dépôt : elles sont déjà dans le
# rootfs via les overlays `image/` et les COPY du Containerfile.
set -Eeuo pipefail

ROOTFS="${1:?chemin du rootfs requis}"
TARGET="${2:-unknown}"

[[ -d "$ROOTFS" ]] || {
  echo "ERREUR : rootfs introuvable : $ROOTFS" >&2
  exit 1
}

echo "==> Finalisation du rootfs ($TARGET)"

# Artefacts du conteneur et marqueurs de l'arborescence source.
rm -rf "$ROOTFS/.dockerenv"
find "$ROOTFS" -name .gitkeep -delete

# Identité de la machine live. L'installateur réécrit ces fichiers sur la cible.
printf 'liveinstall\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 liveinstall
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# systemd-resolved crée ce lien au premier démarrage ; éviter de figer le
# resolv.conf du conteneur dans le SquashFS.
rm -f "$ROOTFS/etc/resolv.conf"
ln -sfn /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

# Un machine-id unique sera généré au premier démarrage (live et installé).
rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id"
mkdir -p "$ROOTFS/var/lib/dbus"
ln -sfn /etc/machine-id "$ROOTFS/var/lib/dbus/machine-id"

# Les fichiers recréés ci-dessus doivent appartenir à root dans le SquashFS.
chown 0:0 "$ROOTFS/var/lib/dbus"
chown 0:0 "$ROOTFS/etc/hostname" "$ROOTFS/etc/hosts"
chown -h 0:0 "$ROOTFS/etc/resolv.conf" "$ROOTFS/var/lib/dbus/machine-id"
