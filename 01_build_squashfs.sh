# 1. Construire l'image Docker
docker build -t ubuntu-26-custom .

# 2. Créer un conteneur temporaire et exporter le système de fichiers
CONTAINER_ID=$(docker create ubuntu-26-custom)
mkdir -p /tmp/docker-rootfs
docker export $CONTAINER_ID | sudo tar -xf - -C /tmp/docker-rootfs
docker rm $CONTAINER_ID

# 3. Supprimer le fichier d'environnement Docker
sudo rm -rf /tmp/docker-rootfs/.dockerenv

# 4. Compresser en SquashFS (stocké dans votre dossier personnel)
sudo apt update && sudo apt install -y squashfs-tools
sudo mksquashfs /tmp/docker-rootfs ./filesystem.squashfs -comp xz -b 1M

# 5. Nettoyer le dossier temporaire
sudo rm -rf /tmp/docker-rootfs