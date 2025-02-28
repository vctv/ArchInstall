#!/bin/bash

# 参数解析函数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--ssid)
                SSID="$2"
                shift 2
                ;;
            -k|--key)
                PSK="$2"
                shift 2
                ;;
            -x|--proxy)
                PROXY="$2"
                shift 2
                ;;
            -u|--username)
                USERNAME="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD="$2"
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
    echo "  -s, --ssid          wifi name"
    echo "  -p, --key           wifi password"
    echo "  -x, --proxy         the address of the proxy server"
    echo "  -u, --username      username"
    echo "  -p, --password      user and root passwords"
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

# connect to wifi
connect_wifi() {
    if [ -n "$SSID" ]; then
        if [ -n "$PSK" ]; then
            iwctl --passphrase "$PSK" station wlan0 connect "$SSID" >/dev/null 2>&1
        else
            iwctl station wlan0 connect "$SSID" >/dev/null 2>&1
        fi

        if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
            echo "The WiFi connection fails or the network cannot be accessed !"
            exit 1
        fi
    fi
}

# 设置代理
set_proxy() {
    if [ -n "$PROXY" ]; then
        export http_proxy="$PROXY"
        export https_proxy="$PROXY"

        local URL="https://www.google.com"
        local HTTP_CODE=$(curl -s -f -o /dev/null -w "%{http_code}" "$URL")
        if [ "$HTTP_CODE" == "200" ]; then
            echo "Cannot access Google !"
        else
            echo "Unable to access Google, Http status code: $HTTP_CODE"
        fi
    fi
}

update_mirrors() {
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        if ping -c 1 youku.com >/dev/null 2>&1; then
            systemctl stop reflector.service
            mirror_content="Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch\nServer = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch\nServer = https://repo.huaweicloud.com/archlinux/\$repo/os/\$arch\nServer = http://mirror.lzu.edu.cn/archlinux/\$repo/os/\$arch\nServer = http://mirrors.aliyun.com/archlinux/\$repo/os/\$arch"
            cp -a /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
            sed -i "1i $mirror_content" /etc/pacman.d/mirrorlist
        fi
    fi
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
            echo "/：$ROOT_SIZE GiB"
            echo "/home：$HOME_SIZE GiB"
            echo "/boot：$BOOT_SIZE GiB"
            echo "swap：$SWAP_SIZE GiB"
        fi
        exit 1
    done
}

# select the hard drive
target_disk(){
    TARGET_DISK=$(lsblk -dno name,size,type | grep disk | sort -k2 -hr | head -n1 | awk '{print "/dev/"$1}')
    while read -r disk; do
        if fdisk -l "/dev/${disk}" | grep -i "EFI" >/dev/null 2>&1; then
            TARGET_DISK="/dev/${disk}"
        fi
    done < <(lsblk -d -n -o NAME | grep -E "^sd|^nvme|^vd")
    if [[ "$TARGET_DISK" =~ "nvme" ]]; then
        TARGET_DISK_NAME="${TARGET_DISK}p"
    else
        TARGET_DISK_NAME="$TARGET_DISK"
    fi
    wipefs -a $TARGET_DISK
    TARGET_DISK_SIZE=$(lsblk -b -d -n -o SIZE $TARGET_DISK_NAME | awk '{printf "%.0f\n", $1/1024/1024/1024}')
}

create_partitions() {
    CURRENT_POS=$BOOT_SIZE

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
    parted -s "$TARGET_DISK" mkpart primary $FS_TYPE "${CURRENT_POS}GiB" "$((CURRENT_POS + ROOT_SIZE))GiB"
    CURRENT_POS=$((CURRENT_POS + ROOT_SIZE))
    parted -s "$TARGET_DISK" mkpart primary $FS_TYPE "${CURRENT_POS}GiB" 100%

    # force formatting of partitions
    mkfs.fat -F32 -f "${TARGET_DISK_NAME}1"
    mkfs.ext4 -F "${TARGET_DISK_NAME}3"
    mkswap -f "${TARGET_DISK_NAME}2"
    mkfs.ext4 -F "${TARGET_DISK_NAME}4"

    # mount the partition
    mount "${TARGET_DISK_NAME}3" /mnt
    mkdir -p /mnt/boot
    mount "${TARGET_DISK_NAME}1" /mnt/boot
    mkdir -p /mnt/home
    mount "${disk}4" /mnt/home
    swapon "${disk}2"
}

main() {
    FS_TYPE="ext4" # "btrfs"
    LANGUAGE_NATIVE="false"
    SYSTEMNAME="archlinux"
    USERNAME="cool"
    PASSWORD="looc"
    BOOT_SIZE=1
    parse_args "$@"
    check_boot_mode
    connect_wifi
    set_proxy
    update_mirrors
    target_disk
    distribute
    create_partitions

    wget https://raw.githubusercontent.com/vctv/ArchInstall/refs/heads/master/archlinux.sh -O- | tee /mnt/root/archlinux.sh | (chmod +x /mnt/root/archlinux.sh && arch-chroot /mnt /root/archlinux.sh $TARGET_DISK $USERNAME $PASSWORD KDE)

    umount -R /mnt
}

main "$@"