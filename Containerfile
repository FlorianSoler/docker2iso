# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Base : système commun au live et au système installé
# ---------------------------------------------------------------------------
FROM ubuntu:26.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# 1. Base packages, kernel, GRUB UEFI, network stack, and extended useful tooling
RUN apt-get update && apt-get install -y \
    ubuntu-standard \
    linux-image-generic \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    shim-signed \
    sbsigntool \
    secureboot-db \
    efibootmgr \
    dosfstools \
    parted \
    rsync \
    locales \
    sudo \
    network-manager \
    systemd-sysv \
    iputils-ping \
    vim \
    nano \
    curl \
    wget \
    git \
    net-tools \
    htop \
    bash-completion \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 1b. Les fichiers de configuration du dépôt ne sont pas copiés ici : ils le
#     sont dans chaque étage final (install/live), après toutes les installations
#     de paquets. Ainsi une configuration du dépôt remplace toujours celle
#     générée par les postinst Debian. Voir image/README.md.

# 2. Desktop environment
RUN apt-get update && apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal \
    gnome-terminal \
    fonts-ubuntu \
    xserver-xorg \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# GNOME/GDM needs a writable home directory for its greeter account.
RUN install -d -m 0700 /var/lib/gdm3 && \
    if getent passwd gdm >/dev/null && getent group gdm >/dev/null; then \
      chown gdm:gdm /var/lib/gdm3; \
    fi

# 3. Enable NetworkManager and systemd-resolved for target boot, and setup DNS stub
RUN systemctl enable NetworkManager systemd-resolved

# 4. Configuration of French locales. The LANG defaults are shipped by the
#    image/common overlay (/etc/default/locale and /etc/locale.conf).
RUN locale-gen fr_FR.UTF-8

# 5. User configuration and root password
RUN echo "root:osadmin" | chpasswd && \
    GROUPS="sudo,adm,cdrom,plugdev,audio,video,render,input,netdev,scanner,lp,users" && \
    if getent group bluetooth >/dev/null; then GROUPS="$GROUPS,bluetooth"; fi && \
    useradd -m -s /bin/bash -G "$GROUPS" monuser && \
    echo "monuser:osadmin" | chpasswd

# 6. Regenerate the initramfs once every package is installed.
#    initramfs-tools is installed explicitly because the kernel package no
#    longer pulls it in on Ubuntu 26.04 (casper, which depends on it, is only
#    installed in the live stage). The live stage rebuilds the initramfs again
#    after casper, so that scripts/casper, overlay.ko and isofs.ko are included.
RUN apt-get update && apt-get install -y --no-install-recommends initramfs-tools \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && echo 'RESUME=none' > /etc/initramfs-tools/conf.d/resume \
    && update-initramfs -u -k all


# ---------------------------------------------------------------------------
# install : système propre copié sur le disque (pas de casper, pas d'installateur)
# ---------------------------------------------------------------------------
FROM base AS install

# Arborescence overlay : common d'abord, puis les fichiers propres à la cible.
# Les COPY suivants écrasent les mêmes chemins dans les couches précédentes.
COPY image/common/ /
COPY image/install/ /

RUN apt-get update && apt-get install -y network-manager-gnome && apt-get clean && rm -rf /var/lib/apt/lists/*
# Marqueur Git du dossier d'overlay vide : ne doit pas apparaître dans le rootfs.
RUN rm -f /.gitkeep


# ---------------------------------------------------------------------------
# live : environnement du LiveISO (casper + installateur lancé automatiquement)
# ---------------------------------------------------------------------------
FROM base AS live

# casper ne sert qu'à démarrer le LiveISO, jamais sur le système installé.
RUN apt-get update && apt-get install -y --no-install-recommends casper \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Overlay appliqué après casper pour que les postinst ne réécrivent pas la
# configuration du dépôt. Le stage live ajoute ensuite ses fichiers propres.
COPY image/common/ /
COPY image/live/ /

# L'installateur est un script du dépôt, copié dans l'image live et dans l'ISO.
COPY scripts/install.sh /usr/local/bin/liveinstall

RUN chmod 0755 /usr/local/bin/liveinstall /usr/local/bin/liveinstall-terminal

# Régénérer l'initramfs APRÈS casper pour y inclure scripts/casper,
# overlay.ko et isofs.ko (sinon le boot du live échoue).
RUN update-initramfs -u -k all
