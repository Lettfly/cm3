#!/bin/bash -e
# Install and enable DevTerm systemd services

install -m 644 files/devterm-init.service \
    "${ROOTFS_DIR}/etc/systemd/system/devterm-init.service"

on_chroot << EOF
# Enable DevTerm init service
systemctl enable devterm-init.service

# Enable Bluetooth
systemctl enable bluetooth.service

# Enable NetworkManager
systemctl enable NetworkManager.service
systemctl disable networking.service dhcpcd.service wpa_supplicant.service || true

# Enable SSH
systemctl enable ssh.service

# Disable triggerhappy (not needed, wastes resources on small device)
systemctl disable triggerhappy.service || true
EOF
