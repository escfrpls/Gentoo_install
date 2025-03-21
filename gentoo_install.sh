#!/bin/bash
exec > >(tee /var/log/gentoo_install.log) 2>&1
set -euo pipefail

# --------------------------
# Конфигурация системы
# --------------------------
DISK="/dev/nvme0n1"
BOOT_PART="${DISK}p1"
ROOT_PART="${DISK}p2"
SWAP_PART="${DISK}p3"
HOSTNAME="GentooGaming"
USERNAME="gamer"
TIMEZONE="Europe/Warsaw"
I3_CONFIG_REPO="https://raw.githubusercontent.com/escfrpls/i3-config/main"

# --------------------------
# Проверки перед установкой
# --------------------------
# Проверка архитектуры
if [ "$(uname -m)" != "x86_64" ]; then
    echo "Ошибка: Скрипт предназначен только для архитектуры x86_64!"
    exit 1
fi

# Проверка сети
if ! ping -c1 gentoo.org &>/dev/null; then
    echo "Ошибка: Нет подключения к интернету!"
    exit 1
fi

# Обработка прерывания
trap '{
    echo "Прерывание! Очистка..."
    umount -R /mnt/gentoo || true
    swapoff "$SWAP_PART" || true
    exit 1
}' INT

# --------------------------
# Ввод паролей с проверкой
# --------------------------
set +e
while :; do
    read -sp "Введите пароль root: " ROOT_PASS
    echo
    read -sp "Подтвердите пароль root: " ROOT_PASS_CONFIRM
    echo
    [ "$ROOT_PASS" = "$ROOT_PASS_CONFIRM" ] && break
    echo "Пароли не совпадают!"
done

while :; do
    read -sp "Введите пароль для $USERNAME: " USER_PASS
    echo
    read -sp "Подтвердите пароль для $USERNAME: " USER_PASS_CONFIRM
    echo
    [ "$USER_PASS" = "$USER_PASS_CONFIRM" ] && break
    echo "Пароли не совпадают!"
done
set -e

# --------------------------
# Подтверждение стирания диска
# --------------------------
echo "ВНИМАНИЕ: Будет уничтожена вся информация на $DISK!"
read -p "Подтвердите операцию (введите YES): " confirm
if [ "$confirm" != "YES" ]; then
    echo "Отмена операции."
    exit 1
fi

# --------------------------
# Разметка диска
# --------------------------
wipefs -af "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 513MiB -32GiB
parted -s "$DISK" mkpart primary linux-swap -32GiB 100%

# Создание файловых систем
mkfs.fat -F32 -n EFI "$BOOT_PART"
mkfs.ext4 -L GENTOO "$ROOT_PART"
mkswap -L SWAP "$SWAP_PART"
swapon "$SWAP_PART"

# Монтирование
mount "$ROOT_PART" /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount "$BOOT_PART" /mnt/gentoo/boot

# --------------------------
# Установка Stage3
# --------------------------
STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | 
    grep -v '^#' | awk '/stage3-amd64-openrc/{print $1}')
FULL_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_URL}"

echo "Загрузка Stage3: $FULL_URL"
wget "$FULL_URL" -O /mnt/gentoo/stage3.tar.xz || {
    echo "Ошибка загрузки Stage3!"
    exit 1
}

echo "Распаковка Stage3..."
tar xpf /mnt/gentoo/stage3.tar.xz --xattrs-include='*.*' -C /mnt/gentoo

# --------------------------
# Базовая настройка системы
# --------------------------
# Настройка make.conf
cat <<EOF > /mnt/gentoo/etc/portage/make.conf
COMMON_FLAGS="-march=znver4 -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc)"
EMERGE_DEFAULT_OPTS="--jobs=$(nproc)"

USE="X alsa bluetooth elogind gamemode networkmanager pulseaudio vaapi vulkan wifi lm-sensors vaapi -geoip -geolocate -gnome -kde -nvidia -plasma -systemd -telemetry -telemetry -wayland"
CPU_FLAGS_X86="$(chroot /mnt/gentoo cpuid2cpuflags | cut -d: -f2)"
VIDEO_CARDS="amdgpu radeonsi"
INPUT_DEVICES="libinput"

ACCEPT_KEYWORDS="amd64"
FEATURES="parallel-fetch parallel-install"
GENTOO_MIRRORS="$(mirrorselect -s5 -o)"
EOF

# --------------------------
# Настройка ядра
# --------------------------
chroot /mnt/gentoo emerge -q sys-kernel/gentoo-sources linux-firmware

# Конфигурация для 7900X3D и 7900 XTX
cat <<EOF > /mnt/gentoo/usr/src/linux/.config
CONFIG_AMD_XGBE=y
CONFIG_PCIE_AMD=y
CONFIG_DRM_AMDGPU=y
CONFIG_DRM_AMD_DC_DCN=y
CONFIG_IWLWIFI=m
CONFIG_IWLMVM=m
CONFIG_CFG80211=y
CONFIG_EXTRA_FIRMWARE="amdgpu/aldebaran_smc.bin"
CONFIG_FW_CACHE=y
CONFIG_ZEN3=y
CONFIG_AMD_MEM_ENCRYPT=y
CONFIG_AMD_PMC=y
CONFIG_X86_AMD_PSTATE=y
EOF

# Сборка ядра
chroot /mnt/gentoo /bin/bash <<EOF
cd /usr/src/linux
make olddefconfig
make -j$(nproc) && make modules_install
make install
EOF

# --------------------------
# Установка окружения
# --------------------------
chroot /mnt/gentoo emerge -q \
    x11-wm/i3 \
    x11-misc/i3status \
    x11-terms/st \
    media-fonts/fontawesome \
    net-misc/networkmanager \
    sys-apps/dbus \
    app-admin/doas

# Загрузка конфигов i3
mkdir -p /mnt/gentoo/home/${USERNAME}/.config/{i3,i3status}
wget "${I3_CONFIG_REPO}/config" -O /mnt/gentoo/home/${USERNAME}/.config/i3/config
wget "${I3_CONFIG_REPO}/i3status.conf" -O /mnt/gentoo/home/${USERNAME}/.config/i3status/config

# Настройка AMD GPU
echo "exec_always --no-startup-id amdgpu-clocks --performance" >> /mnt/gentoo/home/${USERNAME}/.config/i3/config

# --------------------------
# Финальная настройка
# --------------------------
# Настройка пользователя
chroot /mnt/gentoo useradd -m -G wheel,audio,video,usb,portage ${USERNAME}
echo "root:${ROOT_PASS}" | chroot /mnt/gentoo chpasswd
echo "${USERNAME}:${USER_PASS}" | chroot /mnt/gentoo chpasswd
unset ROOT_PASS USER_PASS

# Настройка времени
chroot /mnt/gentoo ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
chroot /mnt/gentoo emerge -q net-misc/chrony
chroot /mnt/gentoo rc-update add chronyd default

# Настройка загрузчика
chroot /mnt/gentoo emerge -q sys-boot/grub
chroot /mnt/gentoo grub-install --target=x86_64-efi --efi-directory=/boot
chroot /mnt/gentoo grub-mkconfig -o /boot/grub/grub.cfg

# Очистка
chroot /mnt/gentoo emerge --depclean

echo "Установка завершена! Для входа в систему:"
echo "1. Перезагрузитесь"
echo "2. Войдите под пользователем ${USERNAME}"
echo "3. Запустите NetworkManager: sudo rc-service NetworkManager start"
echo "4. Запустите графическое окружение: startx"
