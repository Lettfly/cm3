#!/bin/bash
# build-native.sh — Build DevTerm CM3 arm32 image natively
# Uses Ubuntu Noble armhf (ports.ubuntu.com) + RPi firmware from GitHub
# Suitable for environments where deb.debian.org / raspbian is blocked.
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
WORK_DIR="${WORK_DIR:-/home/user/cm3-build}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/user/cm3/deploy}"
IMG_NAME="DevTerm-CM3-Trixie-$(date +%Y%m%d)"

ROOTFS="${WORK_DIR}/rootfs"
BOOT_MNT="${WORK_DIR}/boot"
IMG_FILE="${WORK_DIR}/${IMG_NAME}.img"

# Partition sizes
BOOT_MB=256
ROOT_MB=3072   # 3 GB rootfs

UBUNTU_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
UBUNTU_SUITE="noble"   # Ubuntu 24.04 LTS — armhf, Debian trixie equivalent

FIRST_USER=clockwork
FIRST_PASS=clockwork
HOSTNAME=devterm

# GitHub tag for RPi firmware (latest stable CM3/RPi3 compatible)
FIRMWARE_TAG="1.20240529"
FIRMWARE_BASE="https://github.com/raspberrypi/firmware/raw/${FIRMWARE_TAG}/boot"

log() { echo "[$(date +%T)] $*"; }

# ── Prerequisites ──────────────────────────────────────────────────────────────
check_deps() {
    for cmd in debootstrap parted mkfs.vfat mkfs.ext4 qemu-arm-static curl xz; do
        command -v "$cmd" &>/dev/null || { echo "ERROR: missing $cmd"; exit 1; }
    done
}

# ── Ensure binfmt_misc + qemu-arm registered ──────────────────────────────────
setup_binfmt() {
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-arm-rpi ]; then
        mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
        echo ':qemu-arm-rpi:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:F' \
            > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
        log "binfmt_misc: qemu-arm-rpi registered"
    else
        log "binfmt_misc: qemu-arm-rpi already registered"
    fi
}

# ── Create empty image with two partitions ─────────────────────────────────────
create_image() {
    log "Creating image file (${BOOT_MB}MB boot + ${ROOT_MB}MB rootfs)..."
    local total_mb=$(( BOOT_MB + ROOT_MB + 4 ))
    fallocate -l "${total_mb}M" "${IMG_FILE}"

    parted -s "${IMG_FILE}" \
        mklabel msdos \
        mkpart primary fat32  4MiB  $(( 4 + BOOT_MB ))MiB \
        mkpart primary ext4   $(( 4 + BOOT_MB ))MiB 100% \
        set 1 boot on

    # Attach via loop device
    LOOP=$(losetup --find --show --partscan "${IMG_FILE}")
    log "Loop device: ${LOOP}"

    mkfs.vfat -F 32 -n boot   "${LOOP}p1"
    mkfs.ext4 -L rootfs        "${LOOP}p2"

    mkdir -p "${BOOT_MNT}" "${ROOTFS}"
    mount "${LOOP}p2" "${ROOTFS}"
    mkdir -p "${ROOTFS}/boot/firmware"
    mount "${LOOP}p1" "${ROOTFS}/boot/firmware"
}

# ── Download RPi firmware files from GitHub ────────────────────────────────────
download_firmware() {
    log "Downloading RPi firmware (tag: ${FIRMWARE_TAG}) from GitHub..."
    local dst="${ROOTFS}/boot/firmware"
    local files=(
        bootcode.bin
        start.elf
        start_cd.elf
        start4.elf
        fixup.dat
        fixup_cd.dat
        fixup4.dat
        LICENCE.broadcom
        COPYING.linux
        kernel7.img          # ARMv7 32-bit kernel (RPi 3 / CM3)
        bcm2837-rpi-cm3-io3.dtb
        bcm2837-rpi-3-b.dtb
        overlays/miniuart-bt.dtbo
        overlays/i2s-mmap.dtbo
        overlays/dwc2.dtbo
        overlays/gpio-fan.dtbo
    )
    mkdir -p "${dst}/overlays"
    for f in "${files[@]}"; do
        log "  fetching ${f} ..."
        curl -fsSL "${FIRMWARE_BASE}/${f}" -o "${dst}/${f}" || {
            log "  WARNING: could not download ${f}, skipping"
        }
    done
}

# ── Bootstrap Ubuntu Noble armhf rootfs ───────────────────────────────────────
bootstrap_rootfs() {
    log "Bootstrapping Ubuntu Noble armhf rootfs..."
    debootstrap \
        --arch=armhf \
        --components=main,universe,multiverse \
        --foreign \
        "${UBUNTU_SUITE}" \
        "${ROOTFS}" \
        "${UBUNTU_MIRROR}"

    # Copy qemu-arm-static so we can chroot into armhf rootfs on x86_64
    cp /usr/bin/qemu-arm-static "${ROOTFS}/usr/bin/"

    log "Running debootstrap second stage inside armhf chroot..."
    chroot "${ROOTFS}" /debootstrap/debootstrap --second-stage
}

# ── Configure rootfs ──────────────────────────────────────────────────────────
configure_rootfs() {
    log "Configuring rootfs..."

    # APT sources
    cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE} main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-security main restricted universe multiverse
EOF

    # Hostname
    echo "${HOSTNAME}" > "${ROOTFS}/etc/hostname"
    cat > "${ROOTFS}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}
EOF

    # fstab
    BOOT_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP}p1")
    ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP}p2")
    cat > "${ROOTFS}/etc/fstab" <<EOF
PARTUUID=${ROOT_PARTUUID} /              ext4 defaults,noatime  0 1
PARTUUID=${BOOT_PARTUUID} /boot/firmware vfat defaults          0 2
EOF

    # Modules
    cat >> "${ROOTFS}/etc/modules" <<EOF
i2c-dev
i2c-bcm2835
spi-bcm2835
dwc2
EOF

    # Copy boot config files from our stage-devterm
    cp /home/user/cm3/stage-devterm/01-devterm-config/files/config.txt \
       "${ROOTFS}/boot/firmware/config.txt"
    # Generate cmdline.txt with real PARTUUID
    echo "console=serial0,115200 console=tty1 root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 fsck.repair=yes rootwait quiet" \
       > "${ROOTFS}/boot/firmware/cmdline.txt"

    # ALSA config
    cp /home/user/cm3/stage-devterm/01-devterm-config/files/asound.conf \
       "${ROOTFS}/etc/asound.conf"

    # devterm-init script
    install -m 755 /home/user/cm3/stage-devterm/01-devterm-config/files/devterm-init \
        "${ROOTFS}/usr/local/bin/devterm-init"
    install -m 644 /home/user/cm3/stage-devterm/02-devterm-services/files/devterm-init.service \
        "${ROOTFS}/etc/systemd/system/devterm-init.service"
}

# ── Install packages inside chroot ────────────────────────────────────────────
install_packages() {
    log "Installing packages inside armhf chroot..."

    # Bind mounts needed for apt/systemctl
    mount --bind /proc "${ROOTFS}/proc"
    mount --bind /sys  "${ROOTFS}/sys"
    mount --bind /dev  "${ROOTFS}/dev"
    mount --bind /dev/pts "${ROOTFS}/dev/pts"

    # Prevent services from starting during install
    cat > "${ROOTFS}/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
    chmod +x "${ROOTFS}/usr/sbin/policy-rc.d"

    chroot "${ROOTFS}" /bin/bash -e <<CHROOT
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    alsa-utils \
    bluez \
    bluetooth \
    curl \
    fbset \
    fonts-noto \
    fonts-terminus \
    htop \
    i2c-tools \
    network-manager \
    openssh-server \
    python3-rpi.gpio \
    python3-serial \
    python3-smbus \
    screen \
    sudo \
    systemd-sysv \
    tmux \
    vim-tiny \
    wpasupplicant

# Create user
useradd -m -s /bin/bash ${FIRST_USER} || true
echo "${FIRST_USER}:${FIRST_PASS}" | chpasswd
usermod -aG sudo,audio,video,bluetooth,dialout,i2c,spi ${FIRST_USER}

# Enable services
systemctl enable ssh.service devterm-init.service bluetooth.service NetworkManager.service 2>/dev/null || true

# Locale
locale-gen en_US.UTF-8 || true

apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

    rm -f "${ROOTFS}/usr/sbin/policy-rc.d"
}

# ── Unmount and package image ─────────────────────────────────────────────────
finalize() {
    log "Finalising image..."

    # Unmount bind mounts
    for m in "${ROOTFS}/dev/pts" "${ROOTFS}/dev" "${ROOTFS}/sys" "${ROOTFS}/proc"; do
        umount "$m" 2>/dev/null || true
    done

    # Remove qemu binary from rootfs
    rm -f "${ROOTFS}/usr/bin/qemu-arm-static"

    sync
    umount "${ROOTFS}/boot/firmware"
    umount "${ROOTFS}"
    losetup -d "${LOOP}"

    log "Compressing image → ${IMG_NAME}.img.xz ..."
    mkdir -p "${DEPLOY_DIR}"
    xz -T0 -c "${IMG_FILE}" > "${DEPLOY_DIR}/${IMG_NAME}.img.xz"
    sha256sum "${DEPLOY_DIR}/${IMG_NAME}.img.xz" > "${DEPLOY_DIR}/${IMG_NAME}.img.xz.sha256"

    log "Done! Image written to:"
    ls -lh "${DEPLOY_DIR}/${IMG_NAME}"*
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    log "Cleanup on exit..."
    for m in "${ROOTFS}/dev/pts" "${ROOTFS}/dev" "${ROOTFS}/sys" "${ROOTFS}/proc" \
              "${ROOTFS}/boot/firmware" "${ROOTFS}"; do
        umount "$m" 2>/dev/null || true
    done
    [ -n "${LOOP:-}" ] && losetup -d "${LOOP}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "${WORK_DIR}"
check_deps
setup_binfmt
create_image
download_firmware
bootstrap_rootfs
configure_rootfs
install_packages
finalize
log "Build complete: ${DEPLOY_DIR}/${IMG_NAME}.img.xz"
