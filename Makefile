SHELL := /bin/bash
.DEFAULT_GOAL := iso

LIVE_SQUASHFS    := filesystem.squashfs
INSTALL_SQUASHFS := install.squashfs
ISO_DIR  := iso
ISO_OUT  := custom-installer.iso
VOLID    := CUSTOM_LINUX_INSTALLER
BUILD_DIR := build
BIOS_ISO := $(BUILD_DIR)/bios.iso

SQUASHFS_DEPS := dockerfile 01_build_squashfs.sh 02_vm_install.sh liveinstall-terminal.sh liveinstall-autostart.desktop config/keyboard config/grub
ISO_DEPS := 03_build_efi.sh config/efi-grub.cfg iso/boot/grub/grub.cfg

.PHONY: all iso squashfs clean distclean run

all: iso
squashfs: $(LIVE_SQUASHFS) $(INSTALL_SQUASHFS)

# Cible groupée : le script produit les deux SquashFS en une seule passe.
$(LIVE_SQUASHFS) $(INSTALL_SQUASHFS) &: $(SQUASHFS_DEPS)
	./01_build_squashfs.sh

iso: $(LIVE_SQUASHFS) $(INSTALL_SQUASHFS) $(ISO_DEPS)
	@set -euo pipefail; \
	command -v grub-mkrescue >/dev/null || { echo "Manque grub-mkrescue (paquets : grub-pc-bin grub-efi-amd64-bin xorriso mtools)"; exit 1; }; \
	test -d /usr/lib/grub/i386-pc || { echo "Manque les modules GRUB BIOS (/usr/lib/grub/i386-pc)"; exit 1; }; \
	command -v xorriso >/dev/null || { echo "Manque xorriso (paquet : xorriso)"; exit 1; }; \
	command -v unsquashfs >/dev/null || { echo "Manque unsquashfs (paquet : squashfs-tools)"; exit 1; }; \
	command -v mkfs.fat >/dev/null || { echo "Manque mkfs.fat (paquet : dosfstools)"; exit 1; }; \
	command -v mcopy >/dev/null || { echo "Manque mcopy (paquet : mtools)"; exit 1; }; \
	KVER=$$(unsquashfs -l $(LIVE_SQUASHFS) 2>/dev/null | sed -n 's#^squashfs-root/boot/vmlinuz-\(.*\)$$#\1#p' | sort -V | tail -1); \
	test -n "$$KVER" || { echo "Kernel introuvable dans $(LIVE_SQUASHFS)"; exit 1; }; \
	echo "Kernel utilisé : $$KVER"; \
	rm -f $(ISO_OUT) $(BIOS_ISO); \
	mkdir -p $(ISO_DIR)/casper $(ISO_DIR)/live $(ISO_DIR)/install $(ISO_DIR)/EFI/ubuntu $(BUILD_DIR)/bios-tree; \
	rm -f $(ISO_DIR)/casper/filesystem.squashfs $(ISO_DIR)/casper/install.squashfs; \
	cp $(LIVE_SQUASHFS) $(ISO_DIR)/casper/filesystem.squashfs; \
	cp $(INSTALL_SQUASHFS) $(ISO_DIR)/casper/install.squashfs; \
	install -m 0755 02_vm_install.sh $(ISO_DIR)/install/02_vm_install.sh; \
	unsquashfs -cat $(LIVE_SQUASHFS) boot/vmlinuz-$$KVER > $(ISO_DIR)/live/vmlinuz; \
	unsquashfs -cat $(LIVE_SQUASHFS) boot/initrd.img-$$KVER > $(ISO_DIR)/live/initrd; \
	chmod 0644 $(ISO_DIR)/live/vmlinuz $(ISO_DIR)/live/initrd; \
	./03_build_efi.sh $(LIVE_SQUASHFS) $(ISO_DIR)/efi.img; \
	install -m 0644 config/efi-grub.cfg $(ISO_DIR)/EFI/ubuntu/grub.cfg; \
	rm -rf $(ISO_DIR)/boot/grub/i386-pc; \
	grub-mkrescue -d /usr/lib/grub/i386-pc -o $(BIOS_ISO) $(BUILD_DIR)/bios-tree -- -volid "$(VOLID)"; \
	xorriso -osirrox on -indev $(BIOS_ISO) -extract /boot/grub/i386-pc $(ISO_DIR)/boot/grub/i386-pc; \
	chmod -R u+rwX,go+rX $(ISO_DIR)/boot/grub/i386-pc; \
	rm -f $(BIOS_ISO); \
	rm -rf $(BUILD_DIR)/bios-tree; \
	( cd $(ISO_DIR) && find . -type f ! -name md5sum.txt ! -path './efi.img' ! -path './boot/grub/i386-pc/*' -print0 | sort -z | xargs -0 md5sum > md5sum.txt ); \
	xorriso -as mkisofs -r -V "$(VOLID)" -o $(ISO_OUT) \
	  -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
	  -eltorito-alt-boot -e /efi.img -no-emul-boot \
	  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
	  --protective-msdos-label -partition_cyl_align off -partition_offset 0 -partition_hd_cyl 182 -partition_sec_hd 32 \
	  -apm-block-size 2048 -hfsplus \
	  -efi-boot-part --efi-boot-image \
	  $(ISO_DIR); \
	echo "ISO prête : $(ISO_OUT)"

clean:
	rm -f $(ISO_OUT)
	rm -f $(ISO_DIR)/casper/filesystem.squashfs $(ISO_DIR)/casper/install.squashfs
	rm -f $(ISO_DIR)/live/vmlinuz $(ISO_DIR)/live/initrd
	rm -f $(ISO_DIR)/md5sum.txt
	rm -f $(ISO_DIR)/efi.img
	rm -rf $(ISO_DIR)/EFI
	rm -rf $(ISO_DIR)/boot/grub/i386-pc
	rm -rf $(BUILD_DIR)

distclean: clean
	rm -f $(LIVE_SQUASHFS) $(INSTALL_SQUASHFS)

run: iso
	qemu-system-x86_64 -m 4096 -enable-kvm -cdrom $(ISO_OUT) -boot d
