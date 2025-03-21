#!/bin/bash
exec > >(tee /var/log/gentoo_install.log) 2>&1
set -euo pipefail

# --------------------------
# System Configuration
# --------------------------
DISK="/dev/nvme0n1"
BOOT_PART="${DISK}p1"
ROOT_PART="${DISK}p2"
SWAP_PART="${DISK}p3"
HOSTNAME="GentooLove"
USERNAME="EscFrPls"
TIMEZONE="Europe/Warsaw"

# Hardware Specific
CPU_VENDOR="amd"
GPU_VENDOR="amdgpu"
WIFI_CHIPSET="intel"  # Для B650 Gaming WiFi (AX200/AX210)

# --------------------------
# Architecture Check
# --------------------------
if [ "$(uname -m)" != "x86_64" ]; then
    echo "Error: This script is for x86_64 architecture only!"
    exit 1
fi

# --------------------------
# Interrupt Handler
# --------------------------
trap cleanup INT
cleanup() {
    echo "Aborting installation..."
    umount -R /mnt/gentoo || true
    swapoff "$SWAP_PART" || true
    exit 1
}

# --------------------------
# Disk Space Check
# --------------------------
check_disk_space() {
    local needed=15 # GB
    local available=$(df -BG /mnt/gentoo | awk 'NR==2{print $4}' | tr -d 'G')
    
    if [ "$available" -lt "$needed" ]; then
        echo "Error: Need at least ${needed}GB free space"
        exit 1
    fi
}

# --------------------------
# Password Input with Verification
# --------------------------
set +e
while :; do
    read -sp "Enter root password: " ROOT_PASS
    echo
    read -sp "Confirm root password: " ROOT_PASS_CONFIRM
    echo
    [ "$ROOT_PASS" = "$ROOT_PASS_CONFIRM" ] && break
    echo "Passwords do not match, try again."
done

while :; do
    read -sp "Enter password for $USERNAME: " USER_PASS
    echo
    read -sp "Confirm password for $USERNAME: " USER_PASS_CONFIRM
    echo
    [ "$USER_PASS" = "$USER_PASS_CONFIRM" ] && break
    echo "Passwords do not match, try again."
done
set -e
unset ROOT_PASS_CONFIRM USER_PASS_CONFIRM

# --------------------------
# Disk Safety Check
# --------------------------
echo "WARNING: About to wipe ALL data on $DISK!"
echo -n "Are you absolutely sure? (type uppercase YES): "
read confirmation
if [ "$confirmation" != "YES" ]; then
    echo "Aborted by user."
    exit 1
fi

# --------------------------
# Disk Preparation
# --------------------------
wipefs -af "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 513MiB -32GiB
parted -s "$DISK" mkpart primary linux-swap -32GiB 100%

# --------------------------
# Creating Filesystems
# --------------------------
mkfs.fat -F 32 -n BOOT "$BOOT_PART"
mkfs.ext4 -L GENTOO -F "$ROOT_PART"
mkswap -L SWAP "$SWAP_PART"
swapon "$SWAP_PART"

# --------------------------
# Mounting Partitions
# --------------------------
mount "$ROOT_PART" /mnt/gentoo || { echo "Failed to mount root partition"; exit 1; }
mkdir -p /mnt/gentoo/boot
mount "$BOOT_PART" /mnt/gentoo/boot || { echo "Failed to mount boot partition"; exit 1; }

# --------------------------
# Stage3 Download & Extraction
# --------------------------
STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v '^#' | awk '{print $1}')
FULL_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_URL}"
echo "Downloading stage3: $FULL_URL"
wget "$FULL_URL" -O /mnt/gentoo/stage3.tar.xz || { echo "Stage3 download failed"; exit 1; }

echo "Extracting stage3..."
tar xpf /mnt/gentoo/stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo

# --------------------------
# CPU-Specific Optimizations
# --------------------------
chroot /mnt/gentoo emerge -q app-misc/resolve-march-native
MARCH_NATIVE=$(chroot /mnt/gentoo resolve-march-native)
CPU_FLAGS=$(chroot /mnt/gentoo cpuid2cpuflags | cut -d: -f2)

# --------------------------
# make.conf Configuration
# --------------------------
cat <<EOF > /mnt/gentoo/etc/portage/make.conf
COMMON_FLAGS="${MARCH_NATIVE} -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j\$(nproc)"
ACCEPT_KEYWORDS="amd64"
CPU_FLAGS_X86="${CPU_FLAGS}"

USE="
    bluetooth
    elogind
    gui
    vulkan
    wayland
    X
    alsa
    pulseaudio
    vaapi
    vdpau
    networkmanager
    wifi
    -systemd
"

VIDEO_CARDS="amdgpu radeonsi"
INPUT_DEVICES="libinput evdev"

LINGUAS="en ru"
L10N="en ru"

GENTOO_MIRRORS="\$(mirrorselect -s5 -o)"
FEATURES="parallel-fetch parallel-install"
EOF

# --------------------------
# Hardware-Specific Kernel Config
# --------------------------
cat <<EOF > /mnt/gentoo/usr/src/linux/.config
# Ядро для AMD Ryzen 9 7900X3D и Radeon RX 7900 XTX
CONFIG_AMD_XGBE=y
CONFIG_PCIE_AMD=y
CONFIG_AMD_IOMMU=y
CONFIG_SENSORS_ASUS_WMI=y
CONFIG_IWLWIFI=y
CONFIG_IWLMVM=y
CONFIG_IWLWIFI_PCI=y
CONFIG_CFG80211=y
CONFIG_DRM_AMDGPU=y
CONFIG_DRM_AMD_DC_DCN=y
CONFIG_DRM_AMD_SECURE_DISPLAY=y
CONFIG_AMD_PMC=y
CONFIG_X86_AMD_PSTATE=y
CONFIG_DRM_AMDGPU_CIK=y
CONFIG_DRM_AMDGPU_USERPTR=y
CONFIG_HSA_AMD=y
CONFIG_AMD_MEM_ENCRYPT=y
CONFIG_CRYPTO_DEV_CCP=y
CONFIG_ZEN3=y
EOF

# --------------------------
# Build Kernel
# --------------------------
chroot /mnt/gentoo emerge -q sys-kernel/gentoo-sources linux-firmware iw wpa_supplicant

echo "Configuring kernel..."
chroot /mnt/gentoo /bin/bash <<EOF
cd /usr/src/linux
make olddefconfig
make -j\$(nproc) && make modules_install
make install
EOF

# --------------------------
# System Configuration
# --------------------------
# Профиль
chroot /mnt/gentoo eselect profile set default/linux/amd64/17.1/desktop/openrc

# Пароли
echo "root:${ROOT_PASS}" | chroot /mnt/gentoo chpasswd
unset ROOT_PASS

# Пользователь
chroot /mnt/gentoo useradd -m -G wheel,audio,video,input,plugdev,portage,network ${USERNAME}
echo "${USERNAME}:${USER_PASS}" | chroot /mnt/gentoo chpasswd
unset USER_PASS

# Сеть
chroot /mnt/gentoo emerge -q net-misc/networkmanager
chroot /mnt/gentoo rc-update add NetworkManager default

# Wi-Fi
chroot /mnt/gentoo emerge -q net-wireless/iw net-wireless/wpa_supplicant

# --------------------------
# GPU Configuration
# --------------------------
chroot /mnt/gentoo emerge -q \
    x11-drivers/xf86-video-amdgpu \
    media-libs/mesa \
    media-libs/vulkan-loader \
    media-libs/vulkan-radeon

# --------------------------
# Final Setup
# --------------------------
# Временная зона
chroot /mnt/gentoo ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

# GRUB
chroot /mnt/gentoo emerge -q sys-boot/grub efibootmgr
chroot /mnt/gentoo grub-install --target=x86_64-efi --efi-directory=/boot
chroot /mnt/gentoo grub-mkconfig -o /boot/grub/grub.cfg

# Очистка
chroot /mnt/gentoo emerge --depclean
chroot /mnt/gentoo eselect shell set /bin/zsh

echo "Installation complete! Reboot and enjoy your gaming rig!"
