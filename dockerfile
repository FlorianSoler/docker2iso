FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Base packages, kernel, GRUB UEFI, network stack, and extended useful tooling
RUN apt-get update && apt-get install -y \
    ubuntu-standard \
    casper \
    linux-image-generic \
    grub-efi-amd64 \
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

RUN apt-get update && apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal \
    gnome-terminal \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Enable NetworkManager and systemd-resolved for target boot, and setup DNS stub
RUN systemctl enable NetworkManager systemd-resolved

# 3. Configuration of French locales
RUN locale-gen fr_FR.UTF-8 && update-locale LANG=fr_FR.UTF-8

# 4. Default keyboard configuration (French)
RUN mkdir -p /etc/default && cat << 'EOF' > /etc/default/keyboard
XKBMODEL="pc105"
XKBLAYOUT="fr"
XKBVARIANT=""
XKBOPTIONS=""
BACKEND="console-setup"
EOF

# 5. User configuration and root password
RUN echo "root:osadmin" | chpasswd && \
    useradd -m -s /bin/bash -G sudo,adm,cdrom,plugdev monuser && \
    echo "monuser:osadmin" | chpasswd

# 6. Clean pre-configuration of GRUB in /etc/default/grub
RUN cat << 'EOF' > /etc/default/grub
GRUB_DEFAULT="0"
GRUB_TIMEOUT="5"
GRUB_TIMEOUT_STYLE="menu"
GRUB_DISABLE_LINUX_UUID="false"
EOF

# 7. Regenerate the initramfs once every package is installed.
#    This is required so that casper and its kernel modules (overlay, isofs, ...)
#    are really included. Running update-initramfs during the package
#    installation can produce an initramfs without those modules.
RUN echo 'RESUME=none' > /etc/initramfs-tools/conf.d/resume && \
    update-initramfs -u -k all