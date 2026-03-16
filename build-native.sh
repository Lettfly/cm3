#!/bin/bash
# build-native.sh — Build DevTerm CM3 arm32 image natively
# Target: WSL2 Ubuntu 22.04 x64 (or any Debian/Ubuntu x86_64 host)
# Uses Debian Trixie armhf + RPi firmware from GitHub
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/work}"
DEPLOY_DIR="${DEPLOY_DIR:-${SCRIPT_DIR}/deploy}"
IMG_NAME="DevTerm-CM3-Trixie-$(date +%Y%m%d)"

ROOTFS="${WORK_DIR}/rootfs"
IMG_FILE="${WORK_DIR}/${IMG_NAME}.img"

# Partition sizes
BOOT_MB=256
ROOT_MB=3072   # 3 GB rootfs

FIRST_USER=lett
FIRST_PASS=hell
TARGET_HOSTNAME=devterm

# GitHub tag for RPi firmware (latest stable CM3/RPi3 compatible)
FIRMWARE_TAG="1.20240529"
FIRMWARE_BASE="https://github.com/raspberrypi/firmware/raw/${FIRMWARE_TAG}/boot"

log() { echo "[$(date +%T)] $*"; }

# ── Auto-detect accessible mirrors ──────────────────────────────────────────
detect_mirrors() {
    log "Detecting accessible mirrors..."
    if curl -s --max-time 5 http://deb.debian.org/debian/dists/trixie/Release -o /dev/null -w '' 2>/dev/null \
       && [ "$(curl -s --max-time 5 http://deb.debian.org/debian/dists/trixie/Release -o /dev/null -w '%{http_code}' 2>/dev/null)" = "200" ]; then
        BOOTSTRAP_MIRROR="http://deb.debian.org/debian"
        BOOTSTRAP_SUITE="trixie"
        BOOTSTRAP_COMPONENTS="main,contrib,non-free,non-free-firmware"
        USE_RPI_REPO=1
        log "  Using Debian Trixie (full network access)"
    elif curl -s --max-time 5 http://ports.ubuntu.com/ubuntu-ports/dists/noble/Release -o /dev/null -w '' 2>/dev/null \
       && [ "$(curl -s --max-time 5 http://ports.ubuntu.com/ubuntu-ports/dists/noble/Release -o /dev/null -w '%{http_code}' 2>/dev/null)" = "200" ]; then
        BOOTSTRAP_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
        BOOTSTRAP_SUITE="noble"
        BOOTSTRAP_COMPONENTS="main,restricted,universe,multiverse"
        USE_RPI_REPO=0
        log "  Using Ubuntu Noble armhf (restricted network fallback)"
    else
        log "ERROR: No accessible armhf mirror found (tried deb.debian.org, ports.ubuntu.com)"
        exit 1
    fi
}

# ── Install host build dependencies (Ubuntu 22.04) ───────────────────────────
install_deps() {
    log "Checking / installing build dependencies..."
    local pkgs=(
        debootstrap parted dosfstools e2fsprogs xz-utils
        qemu-user-static binfmt-support
        curl kpartx mtools rsync
    )
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" &>/dev/null || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log "Installing: ${missing[*]}"
        apt-get update -qq
        apt-get install -y "${missing[@]}"
    fi
}

# ── Ensure binfmt_misc + qemu-arm registered ──────────────────────────────────
setup_binfmt() {
    if [ ! -d /proc/sys/fs/binfmt_misc ]; then
        mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    fi
    # On WSL2 with qemu-user-static + binfmt-support, it's usually auto-registered
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-arm ]; then
        update-binfmts --enable qemu-arm 2>/dev/null || true
        # Fallback: manual registration
        if [ ! -f /proc/sys/fs/binfmt_misc/qemu-arm ] && \
           [ ! -f /proc/sys/fs/binfmt_misc/qemu-arm-rpi ]; then
            local qemu_bin
            qemu_bin=$(which qemu-arm-static 2>/dev/null || echo /usr/bin/qemu-arm-static)
            echo ":qemu-arm-rpi:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${qemu_bin}:F" \
                > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
        fi
    fi
    log "binfmt_misc: $(ls /proc/sys/fs/binfmt_misc/qemu-arm* 2>/dev/null || echo 'registered via system')"
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

    # Attach via loop device with partition scanning
    LOOP=$(losetup --find --show --partscan "${IMG_FILE}")
    log "Loop device: ${LOOP}"

    # Wait for partition devices to appear (WSL2 may be slower)
    local retries=10
    while [ ! -b "${LOOP}p1" ] && [ $retries -gt 0 ]; do
        sleep 0.5
        partprobe "${LOOP}" 2>/dev/null || true
        retries=$((retries - 1))
    done

    if [ -b "${LOOP}p1" ]; then
        log "Partitions detected: ${LOOP}p1, ${LOOP}p2"
    else
        # Fallback: use kpartx for device-mapper based partition access
        log "Partition devices not found, trying kpartx..."
        kpartx -av "${LOOP}"
        local dm_name
        dm_name=$(basename "${LOOP}")
        PART1="/dev/mapper/${dm_name}p1"
        PART2="/dev/mapper/${dm_name}p2"
        USE_KPARTX=1
    fi

    PART1="${PART1:-${LOOP}p1}"
    PART2="${PART2:-${LOOP}p2}"

    mkfs.vfat -F 32 -n boot   "${PART1}"
    mkfs.ext4 -L rootfs -q    "${PART2}"

    mkdir -p "${ROOTFS}"
    mount "${PART2}" "${ROOTFS}"
    mkdir -p "${ROOTFS}/boot/firmware"

    # Try mounting FAT boot partition; if vfat module unavailable, use mtools
    if mount "${PART1}" "${ROOTFS}/boot/firmware" 2>/dev/null; then
        BOOT_MOUNTED=1
        log "Partitions formatted and mounted (vfat direct)"
    else
        BOOT_MOUNTED=0
        # Prepare mtools config for writing to boot partition via mcopy
        BOOT_OFFSET=$(parted -s "${IMG_FILE}" unit B print | awk '/^ 1/{gsub("B",""); print $2}')
        MTOOLSRC_FILE="${WORK_DIR}/mtoolsrc"
        echo "drive b: file=\"${IMG_FILE}\" offset=${BOOT_OFFSET}" > "${MTOOLSRC_FILE}"
        export MTOOLS_SKIP_CHECK=1
        log "Partitions formatted; boot partition via mtools (no vfat kernel module)"
    fi
}

# ── Download RPi firmware files from GitHub ────────────────────────────────────
download_firmware() {
    log "Downloading RPi firmware (tag: ${FIRMWARE_TAG}) from GitHub..."
    local fw_tmp="${WORK_DIR}/firmware-dl"
    local files=(
        bootcode.bin
        start.elf
        start_cd.elf
        start4.elf
        start4cd.elf
        fixup.dat
        fixup_cd.dat
        fixup4.dat
        fixup4cd.dat
        LICENCE.broadcom
        COPYING.linux
        kernel7.img
        bcm2710-rpi-cm3.dtb
        bcm2710-rpi-3-b.dtb
    )
    local overlays=(
        miniuart-bt.dtbo
        dwc2.dtbo
        gpio-fan.dtbo
        i2s-dac.dtbo
    )
    mkdir -p "${fw_tmp}/overlays"
    for f in "${files[@]}"; do
        printf "  %-40s" "${f}"
        curl -fsSL --retry 3 "${FIRMWARE_BASE}/${f}" -o "${fw_tmp}/${f}" 2>/dev/null \
            && echo "OK" || echo "SKIP"
    done
    for f in "${overlays[@]}"; do
        printf "  overlays/%-32s" "${f}"
        curl -fsSL --retry 3 "${FIRMWARE_BASE}/overlays/${f}" -o "${fw_tmp}/overlays/${f}" 2>/dev/null \
            && echo "OK" || echo "SKIP"
    done

    # Copy firmware to boot partition
    if [ "${BOOT_MOUNTED}" = "1" ]; then
        local dst="${ROOTFS}/boot/firmware"
        mkdir -p "${dst}/overlays"
        cp "${fw_tmp}"/*.{bin,elf,dat,dtb,img} "${dst}/" 2>/dev/null || true
        cp "${fw_tmp}"/*.{broadcom,linux} "${dst}/" 2>/dev/null || true
        cp "${fw_tmp}"/overlays/*.dtbo "${dst}/overlays/" 2>/dev/null || true
    else
        MTOOLSRC="${MTOOLSRC_FILE}" mmd b:/overlays 2>/dev/null || true
        for f in "${fw_tmp}"/*.{bin,elf,dat,dtb,img,broadcom,linux}; do
            [ -f "$f" ] || continue
            MTOOLSRC="${MTOOLSRC_FILE}" mcopy -o "$f" "b:/$(basename "$f")" 2>/dev/null || true
        done
        for f in "${fw_tmp}"/overlays/*.dtbo; do
            [ -f "$f" ] || continue
            MTOOLSRC="${MTOOLSRC_FILE}" mcopy -o "$f" "b:/overlays/$(basename "$f")" 2>/dev/null || true
        done
    fi
    log "Firmware download and deploy complete"
}

# ── Bootstrap Debian Trixie armhf rootfs ──────────────────────────────────────
bootstrap_rootfs() {
    log "Bootstrapping ${BOOTSTRAP_SUITE} armhf rootfs (this takes a few minutes)..."
    debootstrap \
        --arch=armhf \
        --components="${BOOTSTRAP_COMPONENTS}" \
        --include=ca-certificates \
        --foreign \
        "${BOOTSTRAP_SUITE}" \
        "${ROOTFS}" \
        "${BOOTSTRAP_MIRROR}"

    # Copy qemu-arm-static so we can chroot into armhf rootfs on x86_64
    cp "$(which qemu-arm-static)" "${ROOTFS}/usr/bin/"

    log "Running debootstrap second stage inside armhf chroot..."
    chroot "${ROOTFS}" /debootstrap/debootstrap --second-stage
    log "Bootstrap complete"
}

# ── Configure rootfs ──────────────────────────────────────────────────────────
configure_rootfs() {
    log "Configuring rootfs..."

    # APT sources
    if [ "${BOOTSTRAP_SUITE}" = "trixie" ]; then
        cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${BOOTSTRAP_MIRROR} trixie main contrib non-free non-free-firmware
deb ${BOOTSTRAP_MIRROR} trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
EOF
    else
        cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${BOOTSTRAP_MIRROR} ${BOOTSTRAP_SUITE} main restricted universe multiverse
deb ${BOOTSTRAP_MIRROR} ${BOOTSTRAP_SUITE}-updates main restricted universe multiverse
deb ${BOOTSTRAP_MIRROR} ${BOOTSTRAP_SUITE}-security main restricted universe multiverse
EOF
    fi

    # Add Raspberry Pi APT repo (if accessible)
    if [ "${USE_RPI_REPO}" = "1" ]; then
        mkdir -p "${ROOTFS}/etc/apt/sources.list.d" "${ROOTFS}/usr/share/keyrings"
        curl -fsSL https://archive.raspberrypi.com/debian/pool/main/r/raspberrypi-archive-keyring/raspberrypi-archive-keyring_2021.1.1+rpt1_all.deb \
            -o "${WORK_DIR}/rpi-keyring.deb" || true
        if [ -f "${WORK_DIR}/rpi-keyring.deb" ]; then
            dpkg-deb -x "${WORK_DIR}/rpi-keyring.deb" "${ROOTFS}/"
            cat > "${ROOTFS}/etc/apt/sources.list.d/raspi.list" <<EOF
deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.com/debian bookworm main
EOF
        fi
    fi

    # Hostname
    echo "${TARGET_HOSTNAME}" > "${ROOTFS}/etc/hostname"
    cat > "${ROOTFS}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${TARGET_HOSTNAME}
EOF

    # fstab — use PARTUUID from the loop device
    local boot_uuid root_uuid
    boot_uuid=$(blkid -s PARTUUID -o value "${PART1}" 2>/dev/null || echo "fixme-boot")
    root_uuid=$(blkid -s PARTUUID -o value "${PART2}" 2>/dev/null || echo "fixme-root")
    cat > "${ROOTFS}/etc/fstab" <<EOF
PARTUUID=${root_uuid}  /               ext4  defaults,noatime  0 1
PARTUUID=${boot_uuid}  /boot/firmware  vfat  defaults          0 2
EOF

    # Kernel modules
    cat >> "${ROOTFS}/etc/modules" <<'MODULES'
i2c-dev
i2c-bcm2835
spi-bcm2835
snd_soc_es8388
dwc2
MODULES

    # DevTerm boot config files
    local config_txt="${SCRIPT_DIR}/stage-devterm/01-devterm-config/files/config.txt"
    local cmdline="console=serial0,115200 console=tty1 root=PARTUUID=${root_uuid} rootfstype=ext4 fsck.repair=yes rootwait quiet"

    if [ "${BOOT_MOUNTED}" = "1" ]; then
        cp "${config_txt}" "${ROOTFS}/boot/firmware/config.txt"
        echo "${cmdline}" > "${ROOTFS}/boot/firmware/cmdline.txt"
    else
        MTOOLSRC="${MTOOLSRC_FILE}" mcopy -o "${config_txt}" b:/config.txt
        echo "${cmdline}" > "${WORK_DIR}/cmdline.txt"
        MTOOLSRC="${MTOOLSRC_FILE}" mcopy -o "${WORK_DIR}/cmdline.txt" b:/cmdline.txt
    fi

    cp "${SCRIPT_DIR}/stage-devterm/01-devterm-config/files/asound.conf" \
       "${ROOTFS}/etc/asound.conf"

    install -m 755 "${SCRIPT_DIR}/stage-devterm/01-devterm-config/files/devterm-init" \
        "${ROOTFS}/usr/local/bin/devterm-init"
    install -m 644 "${SCRIPT_DIR}/stage-devterm/02-devterm-services/files/devterm-init.service" \
        "${ROOTFS}/etc/systemd/system/devterm-init.service"

    log "Configuration complete"
}

# ── Install packages inside chroot ────────────────────────────────────────────
install_packages() {
    log "Installing packages inside armhf chroot..."

    # Bind mounts needed for apt/systemctl
    mount --bind /proc    "${ROOTFS}/proc"
    mount --bind /sys     "${ROOTFS}/sys"
    mount --bind /dev     "${ROOTFS}/dev"
    mount --bind /dev/pts "${ROOTFS}/dev/pts"

    # Prevent services from starting during install
    cat > "${ROOTFS}/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
    chmod +x "${ROOTFS}/usr/sbin/policy-rc.d"

    # DNS for chroot
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"

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
    locales \
    network-manager \
    openssh-server \
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
usermod -aG sudo,audio,video,bluetooth,dialout ${FIRST_USER}

# Enable services
systemctl enable ssh.service bluetooth.service NetworkManager.service 2>/dev/null || true
ln -sf /etc/systemd/system/devterm-init.service \
    /etc/systemd/system/multi-user.target.wants/devterm-init.service 2>/dev/null || true

# Locale
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen en_US.UTF-8 || true
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Console font for 1280x480 screen
sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/'   /etc/default/console-setup 2>/dev/null || true
sed -i 's/^FONTSIZE=.*/FONTSIZE="6x12"/'        /etc/default/console-setup 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

    rm -f "${ROOTFS}/usr/sbin/policy-rc.d"
    log "Package installation complete"
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
    umount "${ROOTFS}/boot/firmware" 2>/dev/null || true
    umount "${ROOTFS}" 2>/dev/null || true

    if [ "${USE_KPARTX:-0}" = "1" ]; then
        kpartx -dv "${LOOP}" 2>/dev/null || true
    fi
    losetup -d "${LOOP}" 2>/dev/null || true

    log "Compressing image -> ${IMG_NAME}.img.xz ..."
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
    if [ "${USE_KPARTX:-0}" = "1" ]; then
        kpartx -dv "${LOOP}" 2>/dev/null || true
    fi
    [ -n "${LOOP:-}" ] && losetup -d "${LOOP}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Main ──────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

mkdir -p "${WORK_DIR}"
install_deps
detect_mirrors
setup_binfmt
create_image
download_firmware
bootstrap_rootfs
configure_rootfs
install_packages
finalize
log "Build complete: ${DEPLOY_DIR}/${IMG_NAME}.img.xz"
