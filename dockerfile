FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Installation du noyau, de GRUB (uniquement UEFI) et des paquets de base
RUN apt-get update && apt-get install -y \
    ubuntu-standard \
    linux-image-generic \
    grub-efi-amd64 \
    locales \
    sudo \
    network-manager \
    systemd-sysv \
    iputils-ping \
    vim \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configuration des locales en français
RUN locale-gen fr_FR.UTF-8 && update-locale LANG=fr_FR.UTF-8

# Configuration de l'utilisateur et du mot de passe root
RUN echo "root:osadmin" | chpasswd && \
    useradd -m -s /bin/bash -G sudo,adm,cdrom,plugdev monuser && \
    echo "monuser:osadmin" | chpasswd