#!/bin/bash
exec > >(tee /var/log/gentoo_install.log) 2>&1
set -e

# System Configuration
DISK="/dev/nvme0n1"
BOOT_PART="${DISK}p1"
ROOT_PART="${DISK}p2"
SWAP_PART="${DISK}p3"
HOSTNAME="GentooHome"
USERNAME="escfrpls"
TIMEZONE="Europe/Warsaw"

# Initial Checks
echo "Checking network..."
if ! ip route | grep -q default; then
    echo "Error: No default route (check network connection)"
    exit 1
fi

if mount | grep -q "$DISK"; then
    echo "Error: Disk is mounted! Unmount first."
    exit 1
fi

# Password Input
read -sp "Enter password for root: " ROOT_PASS
echo
read -sp "Enter password for $USERNAME: " USER_PASS
echo

# Disk Preparation
wipefs -af $DISK
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB 513MiB
parted -s $DISK set 1 esp on
parted -s $DISK mkpart primary ext4 513MiB -32GiB
parted -s $DISK mkpart primary linux-swap -32GiB 100%

# Filesystems
mkfs.fat -F 32 -n BOOT $BOOT_PART
mkfs.ext4 -L GENTOO -F $ROOT_PART
mkswap -L SWAP $SWAP_PART
swapon $SWAP_PART

# Mounting
mount $ROOT_PART /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount $BOOT_PART /mnt/gentoo/boot

# Stage3
STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -o 'https://.*stage3.*tar.xz')
wget $STAGE3_URL -O /mnt/gentoo/stage3.tar.xz
wget "${STAGE3_URL}.CONTENTS" -O /mnt/gentoo/stage3.CONTENTS

echo "Verifying stage3 integrity..."
tar tvf /mnt/gentoo/stage3.tar.xz | awk '{print $6}' > /mnt/gentoo/stage3.LIST
if ! diff -q /mnt/gentoo/stage3.CONTENTS /mnt/gentoo/stage3.LIST; then
    echo "Stage3 integrity check failed!"
    exit 1
fi

tar xpvf /mnt/gentoo/stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo

# Set root password
echo "root:$ROOT_PASS" | chroot /mnt/gentoo chpasswd
unset ROOT_PASS

# Configure make.conf
CPU_FLAGS=$(chroot /mnt/gentoo cpuid2cpuflags | cut -d: -f2)
cat <<EOF > /mnt/gentoo/etc/portage/make.conf
COMMON_FLAGS="-march=znver4 -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc)"
ACCEPT_KEYWORDS="amd64"
CPU_FLAGS_X86="$CPU_FLAGS"

USE="
    X
    acpi
    alsa
    bluetooth
    imagemagick
    lm-sensors
    multilib
    networkmanager
    pulseaudio
    vaapi
    vdpau
    vulkan
    xinerama
    xvmc
    -geoip
    -geolocate
    -gnome
    -kde
    -nvidia
    -plasma
    -systemd
    -telemetry
    -wayland
"

VIDEO_CARDS="amdgpu radeonsi"
INPUT_DEVICES="libinput evdev"

LINGUAS="en ru"
L10N="en ru"

GENTOO_MIRRORS="https://gentoo.mirror.gda.cloud.ovh.net/ http://ftp.icm.edu.pl/pub/Linux/gentoo/"
FEATURES="parallel-fetch parallel-install"
EOF

# Kernel Configuration
chroot /mnt/gentoo emerge -q sys-kernel/gentoo-sources linux-firmware
KERNEL_EXTRA='
CONFIG_HID_SONY=y
CONFIG_HID_XBOX=y
CONFIG_HID_PLAYSTATION=y
CONFIG_SND_USB_AUDIO=y
CONFIG_DRM_AMDGPU=y
CONFIG_IA32_EMULATION=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_R8169=y
CONFIG_R8169_VLAN=y
CONFIG_R8169_NAPI=y
'
echo "$KERNEL_EXTRA" > /mnt/gentoo/usr/src/linux/.config

# Build Kernel
chroot /mnt/gentoo /bin/bash <<EOF
cd /usr/src/linux
make olddefconfig
make -j$(nproc) && make modules_install
make install
EOF

# Add Guru overlay
chroot /mnt/gentoo emerge -q app-eselect/eselect-repository
chroot /mnt/gentoo eselect repository enable guru
chroot /mnt/gentoo emerge --sync

# Install Packages
chroot /mnt/gentoo emerge -q \
    sys-apps/dbus \
    sys-devel/gcc \
    x11-base/xorg-server \
    media-libs/mesa \
    media-libs/vulkan-loader \
    x11-wm/i3 \
    x11-misc/dmenu \
    app-admin/doas \
    media-sound/pulseaudio \
    net-wireless/bluez \
    games-emulation/xboxdrv \
    media-video/vlc \
    app-admin/htop \
    media-libs/alsa-lib \
    media-sound/alsa-utils \
    media-plugins/alsa-plugins \
    www-client/firefox \
    x11-misc/pcmanfm \
    app-editors/vim \
    x11-terms/st \
    app-shells/zsh \
    app-shells/zsh-completion \
    net-misc/networkmanager \
    net-im/signal-desktop-bin \
    net-im/discord-bin \
    games-util/steam-launcher \
    sys-boot/grub \
    efibootmgr

# Cleanup
chroot /mnt/gentoo emerge -q @preserved-rebuild
chroot /mnt/gentoo emerge --depclean

# Network Configuration
chroot /mnt/gentoo rc-update add NetworkManager default

# User Configuration
chroot /mnt/gentoo useradd -m -G wheel,audio,video,input,plugdev,portage,network $USERNAME
echo "$USERNAME:$USER_PASS" | chroot /mnt/gentoo chpasswd
unset USER_PASS

# doas Configuration
echo "permit persist :wheel" > /mnt/gentoo/etc/doas.conf

# Default Shell
chroot /mnt/gentoo eselect shell set /bin/zsh
chroot /mnt/gentoo usermod -s /bin/zsh root
chroot /mnt/gentoo usermod -s /bin/zsh $USERNAME

# Zsh Configuration
cat <<EOF > /mnt/gentoo/home/$USERNAME/.zshrc
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
autoload -Uz compinit
compinit
PROMPT='%F{blue}%n@%m%f %F{green}%~%f %# '
EOF
chroot /mnt/gentoo chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc

# i3 Configuration
mkdir -p /mnt/gentoo/home/$USERNAME/.config/i3
mkdir -p /mnt/gentoo/home/$USERNAME/.config/i3status
wget https://github.com/escfrpls/i3-config/raw/main/config -O /mnt/gentoo/home/$USERNAME/.config/i3/config
wget https://github.com/escfrpls/i3-config/raw/main/i3status.conf -O /mnt/gentoo/home/$USERNAME/.config/i3status/config
echo -e "\n# Set st as default terminal\nbindsym \$mod+Return exec st" >> /mnt/gentoo/home/$USERNAME/.config/i3/config
chroot /mnt/gentoo chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# DisplayPort Configuration
cat <<EOF > /mnt/gentoo/etc/X11/xorg.conf.d/10-monitor.conf
Section "Monitor"
    Identifier "DP-0"
    Modeline "3440x1440_165" 791.50 3440 3696 4064 4688 1440 1443 1453 1527 +hsync -vsync
    Option "PreferredMode" "3440x1440_165"
EndSection

Section "Device"
    Identifier "AMDGPU"
    Driver "amdgpu"
    Option "VariableRefresh" "true"
EndSection
EOF

# System Configuration
chroot /mnt/gentoo ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "en_US.UTF-8 UTF-8" > /mnt/gentoo/etc/locale.gen
chroot /mnt/gentoo locale-gen
echo "LANG=en_US.UTF-8" > /mnt/gentoo/etc/env.d/02locale

# Bootloader
chroot /mnt/gentoo grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
chroot /mnt/gentoo grub-mkconfig -o /boot/grub/grub.cfg

# Final Message
echo "Installation complete! After reboot:"
echo "1. Log in as $USERNAME"
echo "2. Start network: doas rc-service NetworkManager start"
echo "3. Check display: xrandr --output DP-0 --mode 3440x1440 --rate 165"
echo "4. For Steam: steam"
