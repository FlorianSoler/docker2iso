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

# 1b. Fixed configuration files. The legacy Docker builder does not support
#     heredocs, so these files must be copied instead of generated in RUN.
COPY config/keyboard /etc/default/keyboard
COPY config/grub /etc/default/grub

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

# 4. Configuration of French locales
RUN locale-gen fr_FR.UTF-8 && update-locale LANG=fr_FR.UTF-8

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


# ---------------------------------------------------------------------------
# live : environnement du LiveISO (casper + installateur lancé automatiquement)
# ---------------------------------------------------------------------------
FROM base AS live

# casper ne sert qu'à démarrer le LiveISO, jamais sur le système installé.
RUN apt-get update && apt-get install -y --no-install-recommends casper \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Installateur, wrapper de terminal et entrée d'autostart GNOME
COPY 02_vm_install.sh /usr/local/bin/liveinstall
COPY liveinstall-terminal.sh /usr/local/bin/liveinstall-terminal
COPY liveinstall-autostart.desktop /etc/xdg/autostart/liveinstall.desktop

RUN chmod 0755 /usr/local/bin/liveinstall /usr/local/bin/liveinstall-terminal

# Régénérer l'initramfs APRÈS casper pour y inclure scripts/casper,
# overlay.ko et isofs.ko (sinon le boot du live échoue).
RUN update-initramfs -u -k all
