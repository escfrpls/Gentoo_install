#!/bin/bash
exec > >(tee /var/log/gentoo_install.log) 2>&1
set -e

# --------------------------
# System Configuration (VM Optimized)
# --------------------------
DISK="/dev/sda"
BOOT_PART="${DISK}1"
ROOT_PART="${DISk}2"
SWAP_PART="${DISK}3"
HOSTNAME="GentooVM"
USERNAME="vmuser"
TIMEZONE="Europe/Warsaw"

# --------------------------
# Hardware Settings (4 cores, 4GB RAM)
# --------------------------
CPU_CORES=4
SWAP_SIZE="4GiB"

# --------------------------
# Initial Checks
# --------------------------
echo "Checking network connectivity..."
if ! ip route | grep -q default; then
    echo "Error: No default route found (check your network connection)"
    exit 1
fi

# --------------------------
# Disk Preparation (VM Friendly Layout)
# --------------------------
wipefs -af $DISK
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB 513MiB
parted -s $DISK set 1 esp on
parted -s $DISK mkpart primary ext4 513MiB -$SWAP_SIZE
parted -s $DISK mkpart primary linux-swap -$SWAP_SIZE 100%

# --------------------------
# Filesystems (Basic VM Setup)
# --------------------------
mkfs.fat -F 32 -n BOOT $BOOT_PART
mkfs.ext4 -L GENTOO -F $ROOT_PART
mkswap -L SWAP $SWAP_PART
swapon $SWAP_PART

# --------------------------
# Mounting Partitions
# --------------------------
mount $ROOT_PART /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount $BOOT_PART /mnt/gentoo/boot

# --------------------------
# Stage3 Installation (Generic x86_64)
# --------------------------
STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -o 'https://.*stage3.*tar.xz')
wget "$STAGE3_URL" -O /mnt/gentoo/stage3.tar.xz
tar xpvf /mnt/gentoo/stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo

# --------------------------
# Base Configuration (VM Optimized)
# --------------------------
cat <<EOF > /mnt/gentoo/etc/portage/make.conf
COMMON_FLAGS="-march=x86-64 -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${CPU_CORES}"
ACCEPT_KEYWORDS="amd64"

USE="
    acpi
    alsa
    consolekit
    elogind
    networkmanager
    -gnome
    -kde
    -nvidia
    -systemd
    -wayland
"

VIDEO_CARDS="fbdev vesa virtio"
INPUT_DEVICES="libinput"

GENTOO_MIRRORS="https://gentoo.mirror.gda.cloud.ovh.net/ http://ftp.icm.edu.pl/pub/Linux/gentoo/"
FEATURES="parallel-fetch parallel-install"
EOF

# --------------------------
# Kernel Configuration (Virtualization Support)
# --------------------------
chroot /mnt/gentoo emerge -q sys-kernel/gentoo-sources linux-firmware

# VirtIO and essential drivers
KERNEL_CONFIG='
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_FB_VESA=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_SERIO_I8042=y
CONFIG_KEYBOARD_ATKBD=y
CONFIG_MOUSE_PS2=y
CONFIG_TTY=y
CONFIG_VT=y
'
echo "$KERNEL_CONFIG" > /mnt/gentoo/usr/src/linux/.config

# --------------------------
# Build Kernel with VirtIO Support
# --------------------------
chroot /mnt/gentoo /bin/bash <<EOF
cd /usr/src/linux
make olddefconfig
make -j${CPU_CORES} && make modules_install
make install
EOF

# --------------------------
# Essential Packages (Lightweight VM Setup)
# --------------------------
chroot /mnt/gentoo emerge -q \
    sys-apps/dbus \
    sys-devel/gcc \
    app-admin/doas \
    app-admin/sudo \
    sys-boot/grub \
    net-misc/networkmanager \
    sys-apps/hwids \
    app-editors/vim \
    app-shells/zsh

# --------------------------
# Bootloader (BIOS/UEFI Compatible)
# --------------------------
# For UEFI:
chroot /mnt/gentoo grub-install --target=x86_64-efi --efi-directory=/boot
# For BIOS:
# chroot /mnt/gentoo grub-install $DISK
chroot /mnt/gentoo grub-mkconfig -o /boot/grub/grub.cfg

# --------------------------
# User Configuration
# --------------------------
chroot /mnt/gentoo useradd -m -G wheel,audio,video,input $USERNAME
echo "permit persist :wheel" > /mnt/gentoo/etc/doas.conf

# --------------------------
# Final System Tuning
# --------------------------
chroot /mnt/gentoo emerge -q @preserved-rebuild
chroot /mnt/gentoo emerge --depclean
chroot /mnt/gentoo rc-update add NetworkManager default

# --------------------------
# Post-Install Message
# --------------------------
echo "VM Installation Complete!"
echo "1. Start NetworkManager: rc-service NetworkManager start"
echo "2. Login with username: $USERNAME"
echo "3. Recommended: emerge xorg-server xfce4 for GUI"
