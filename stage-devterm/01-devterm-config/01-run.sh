#!/bin/bash -e
# Configure DevTerm CM3 hardware settings

# Deploy configuration files
install -m 644 files/config.txt     "${ROOTFS_DIR}/boot/firmware/config.txt"
install -m 644 files/cmdline.txt    "${ROOTFS_DIR}/boot/firmware/cmdline.txt"
install -m 644 files/modules        "${ROOTFS_DIR}/etc/modules"
install -m 644 files/asound.conf    "${ROOTFS_DIR}/etc/asound.conf"
install -m 755 files/devterm-init   "${ROOTFS_DIR}/usr/local/bin/devterm-init"

on_chroot << EOF
# Enable required kernel modules on boot
if ! grep -q "i2c-dev" /etc/modules; then
    echo "i2c-dev" >> /etc/modules
fi
if ! grep -q "snd_soc_es8388" /etc/modules; then
    echo "snd_soc_es8388" >> /etc/modules
fi

# Enable I2C, SPI, UART interfaces
raspi-config nonint do_i2c 0
raspi-config nonint do_spi 0
raspi-config nonint do_serial_hw 0
raspi-config nonint do_serial_cons 1

# Set GPU memory split
raspi-config nonint do_memory_split 64

# Configure fbset for 1280x480 display
echo 'FRAMEBUFFER_WIDTH=1280'  >> /etc/environment
echo 'FRAMEBUFFER_HEIGHT=480' >> /etc/environment

# Set console font suitable for small screen
sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/'   /etc/default/console-setup || true
sed -i 's/^FONTSIZE=.*/FONTSIZE="6x12"/'        /etc/default/console-setup || true
EOF
