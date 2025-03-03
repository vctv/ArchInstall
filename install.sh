#!/bin/bash

# 参数解析函数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--disk)
                TARGET_DISK="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    echo "Arch Linux install script"
    echo "usage: $0 [options]"
    echo "options:"
    echo "  -d, --disk      TARGET_DISK"
    echo "  -h, --help          displays help information"
}

# check the system boot mode
check_boot_mode() {
    if [ -d "/sys/firmware/efi/efivars" ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi
}

update_mirrors() {
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        if ping -c 1 youku.com >/dev/null 2>&1; then
            systemctl stop reflector.service
            mirror_content="Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch\nServer = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch\nServer = https://repo.huaweicloud.com/archlinux/\$repo/os/\$arch\nServer = http://mirror.lzu.edu.cn/archlinux/\$repo/os/\$arch\nServer = http://mirrors.aliyun.com/archlinux/\$repo/os/\$arch"
            cp -a /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
            sed -i "1i $mirror_content\n" /etc/pacman.d/mirrorlist
        fi
    fi
}

# select the hard drive
target_disk(){
#    TARGET_DISK=$(lsblk -dno name,size,type | grep disk | sort -k2 -hr | head -n1 | awk '{print "/dev/"$1}')
    if [ -n "$TARGET_DISK" ]; then
      echo "TARGET_DISK - $TARGET_DISK"
    else
      echo "NO TARGET_DISK"
      exit 1
    fi

#    while read -r disk; do
#        if fdisk -l "/dev/${disk}" | grep -i "EFI" >/dev/null 2>&1; then
#            TARGET_DISK="/dev/${disk}"
#        fi
#    done < <(lsblk -d -n -o NAME | grep -E "^sd|^nvme|^vd")

    if [[ "$TARGET_DISK" =~ "nvme" ]]; then
        TARGET_DISK_NAME="${TARGET_DISK}p"
    else
        TARGET_DISK_NAME="$TARGET_DISK"
    fi
    wipefs -a $TARGET_DISK
    TARGET_DISK_SIZE=$(lsblk -b -d -n -o SIZE $TARGET_DISK | awk '{printf "%.0f\n", $1/1024/1024/1024}')
    echo "TARGET_DISK_SIZE - $TARGET_DISK_SIZE"
}

distribute() {
    MEMORY_SIZE=$(free -g | awk '/^Mem:/{print $2}')
    SWAP_SIZE=$MEMORY_SIZE
    local root_size_min=32
    local root_size_max=150
    ROOT_SIZE=$root_size_max
    local separate_home=true

    while true; do
        local remaining=$((TARGET_DISK_SIZE - BOOT_SIZE - SWAP_SIZE - ROOT_SIZE))

        if [ $remaining -gt $root_size_min ] && [ $ROOT_SIZE -ne $root_size_max ]; then
            ROOT_SIZE=$(((remaining + ROOT_SIZE) / 2))
            HOME_SIZE=$((TARGET_DISK_SIZE - BOOT_SIZE - SWAP_SIZE - ROOT_SIZE))
        else
            HOME_SIZE=$remaining
        fi

        if [ $remaining -lt $SWAP_SIZE ]; then
            if [ $ROOT_SIZE -eq $root_size_max ]; then
                ROOT_SIZE=$root_size_min
                continue
            fi
            if [ $SWAP_SIZE -eq $MEMORY_SIZE ]; then
                SWAP_SIZE=$(awk "BEGIN {printf \"%.0f\", $MEMORY_SIZE * 0.6}")
                continue
            fi
        fi

        if [ $HOME_SIZE -gt 0 ]; then
            echo "/         $ROOT_SIZE GiB"
            echo "/home     $HOME_SIZE GiB"
            echo "/boot     $BOOT_SIZE GiB"
            echo "swap      $SWAP_SIZE GiB"
            break
        fi
        echo "unable to install"
        exit 1
    done
}

create_partitions() {
    CURRENT_POS=$BOOT_SIZE
    echo "CURRENT_POS - $CURRENT_POS"

    if [ "$BOOT_MODE" = "UEFI" ]; then
        parted -s "$TARGET_DISK" mklabel gpt
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB "${CURRENT_POS}GiB"
        parted -s "$TARGET_DISK" set 1 esp on
    else
        parted -s "$TARGET_DISK" mklabel msdos
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB "${CURRENT_POS}GiB"
        parted -s "$TARGET_DISK" set 1 boot on
    fi

    parted -s "$TARGET_DISK" mkpart primary linux-swap "${CURRENT_POS}GiB" "$((CURRENT_POS + SWAP_SIZE))GiB"
    CURRENT_POS=$((CURRENT_POS + SWAP_SIZE))
    echo "CURRENT_POS - $CURRENT_POS"
    parted -s "$TARGET_DISK" mkpart primary $FS_TYPE "${CURRENT_POS}GiB" "$((CURRENT_POS + ROOT_SIZE))GiB"
    CURRENT_POS=$((CURRENT_POS + ROOT_SIZE))
    echo "CURRENT_POS - $CURRENT_POS"
    parted -s "$TARGET_DISK" mkpart primary $FS_TYPE "${CURRENT_POS}GiB" 100%

    # force formatting of partitions
    echo "TARGET_DISK_NAME - $TARGET_DISK_NAME"
    mkfs.fat -F32 "${TARGET_DISK_NAME}1"
    mkfs.ext4 "${TARGET_DISK_NAME}3"
    mkswap -f "${TARGET_DISK_NAME}2"
    mkfs.ext4 "${TARGET_DISK_NAME}4"

    # mount the partition
    mount "${TARGET_DISK_NAME}3" /mnt
    mkdir -p /mnt/boot
    mount "${TARGET_DISK_NAME}1" /mnt/boot
    mkdir -p /mnt/home
    mount "${TARGET_DISK_NAME}4" /mnt/home
    swapon "${TARGET_DISK_NAME}2"

    lsblk
}

arch_install(){
  pacstrap /mnt base base-devel linux linux-firmware networkmanager vim sudo zsh zsh-completions --force
  genfstab -U /mnt > /mnt/etc/fstab
}

arch_config(){
  rm -rf /mnt/root/config.sh
  wget https://raw.githubusercontent.com/YangMame/Arch-Linux-Installer/master/config.sh -O /mnt/root/config.sh
  chmod +x /mnt/root/config.sh
  arch-chroot /mnt /root/config.sh
}

main() {
    FS_TYPE="ext4" # "btrfs"
    BOOT_SIZE=1
    parse_args "$@"
    check_boot_mode
    update_mirrors
    target_disk
    distribute
    create_partitions
    arch_install
    arch_config
}

main "$@"