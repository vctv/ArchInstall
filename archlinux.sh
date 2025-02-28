#!/bin/bash

# minimal Arch Linux install
# BOOT_DISK USERNAME PASSWORD desktop

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/^#zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" >> /etc/locale.conf
echo "LANG=en_US.UTF-8" >> /etc/profile

echo "archlinux" > /etc/hostname
echo -e "127.0.0.1  localhost\n::1  localhost\n127.0.1.1 ArchLinux.localdomain  ArchLinux" >> /etc/hosts

# set the root password
echo "root:$3" | chpasswd

# create a new user
useradd -m -G wheel -s /bin/bash "$2"
echo "$2:$3" | chpasswd
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# install the cpu ucode
if grep -qi "intel" /proc/cpuinfo; then
    pacman -S --noconfirm intel-ucode
elif grep -qi "amd" /proc/cpuinfo; then
    pacman -S --noconfirm amd-ucode
else
    echo "Unknown GPU type"
    exit 1
fi

if [ -d "/sys/firmware/efi/efivars" ]; then
    pacman -S --noconfirm grub efibootmgr efivar os-prober
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch --recheck
else
    pacman -S --noconfirm grub efivar os-prober
    grub-install --target=i386-pc $1
fi

sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*quiet.*"/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=5 nowatchdog"/' /etc/default/grub
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# install the desktop environment
if [ -n "$4" ]; then
    if [ "$4"  = "KDE" ]; then
        pacman -S --noconfirm plasma kdebase kdeutils kdegraphics sddm
        systemctl enable sddm
    elif [ "$4"  = "Gnome" ]; then
        pacman -S --noconfirm gnome gnome-terminal
        systemctl enable gdm
    elif [ "$4"  = "Lxde" ]; then
        pacman -S lxde lightdm lightdm-gtk-greeter
        systemctl enable lightdm
    elif [ "$4"  = "Xfce" ]; then
        pacman -S --noconfirm xfce4 xfce4-goodies xfce4-terminal lightdm lightdm-gtk-greeter
        systemctl enable lightdm
    fi
fi
exit