SHELL := /bin/bash
.DEFAULT_GOAL := iso

SQUASHFS := filesystem.squashfs
ISO_DIR  := iso
ISO_OUT  := custom-installer.iso
VOLID    := CUSTOM_LINUX_INSTALLER

.PHONY: all iso squashfs clean distclean run

all: iso
squashfs: $(SQUASHFS)

$(SQUASHFS): dockerfile 01_build_squashfs.sh
	./01_build_squashfs.sh

iso: $(SQUASHFS)
	@set -euo pipefail; \
	command -v grub-mkrescue >/dev/null || { echo "Manque grub-mkrescue (paquets : grub-pc-bin grub-efi-amd64-bin xorriso mtools)"; exit 1; }; \
	command -v unsquashfs >/dev/null || { echo "Manque unsquashfs (paquet : squashfs-tools)"; exit 1; }; \
	KVER=$$(unsquashfs -l $(SQUASHFS) 2>/dev/null | sed -n 's#^squashfs-root/boot/vmlinuz-\(.*\)$$#\1#p' | sort -V | tail -1); \
	test -n "$$KVER" || { echo "Kernel introuvable dans $(SQUASHFS)"; exit 1; }; \
	echo "Kernel utilisé : $$KVER"; \
	mkdir -p $(ISO_DIR)/casper $(ISO_DIR)/live $(ISO_DIR)/install; \
	rm -f $(ISO_DIR)/casper/filesystem.squashfs; \
	cp $(SQUASHFS) $(ISO_DIR)/casper/filesystem.squashfs; \
	install -m 0755 02_vm_install.sh $(ISO_DIR)/install/02_vm_install.sh; \
	unsquashfs -cat $(SQUASHFS) boot/vmlinuz-$$KVER > $(ISO_DIR)/live/vmlinuz; \
	unsquashfs -cat $(SQUASHFS) boot/initrd.img-$$KVER > $(ISO_DIR)/live/initrd; \
	chmod 0644 $(ISO_DIR)/live/vmlinuz $(ISO_DIR)/live/initrd; \
	( cd $(ISO_DIR) && find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum > md5sum.txt ); \
	rm -f $(ISO_OUT); \
	grub-mkrescue -o $(ISO_OUT) $(ISO_DIR) -- -volid "$(VOLID)"; \
	echo "ISO prête : $(ISO_OUT)"

clean:
	rm -f $(ISO_OUT)
	rm -f $(ISO_DIR)/casper/filesystem.squashfs
	rm -f $(ISO_DIR)/live/vmlinuz $(ISO_DIR)/live/initrd
	rm -f $(ISO_DIR)/md5sum.txt

distclean: clean
	rm -f $(SQUASHFS)

run: iso
	qemu-system-x86_64 -m 4096 -enable-kvm -cdrom $(ISO_OUT) -boot d
