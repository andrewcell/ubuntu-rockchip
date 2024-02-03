#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

add_package() {
    local package

    for package in "$@"; do
        package_list+=("${package}")
    done
}

remove_package() {
    local package

    for package in "$@"; do
        package_removal_list+=("${package}")
    done
}

add_task() {
    local task
    local package

    for task in "$@"; do
        for package in $(chroot ${chroot_dir} apt-cache dumpavail | grep-dctrl -nsPackage \( -XFArchitecture arm64 -o -XFArchitecture all \) -a -wFTask "${task}"); do
            package_list+=("${package}")
        done
    done
}

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${RELEASE} ]]; then
    echo "Error: RELEASE is not set"
    exit 1
fi

if [[ -z ${RELASE_VERSION} ]]; then
    echo "Error: RELASE_VERSION is not set"
    exit 1
fi

if [[ -z ${PROJECT} ]]; then
    echo "Error: PROJECT is not set"
    exit 1
fi

if [[ -f "ubuntu-${RELASE_VERSION}-${PROJECT}-arm64.rootfs.tar.xz" ]]; then
    exit 0
fi

# These env vars can cause issues with chroot
unset TMP
unset TEMP
unset TMPDIR

# Prevent dpkg interactive dialogues
export DEBIAN_FRONTEND=noninteractive

# Debootstrap options
arch=arm64
release="${RELEASE}"
mirror=http://ports.ubuntu.com/ubuntu-ports
chroot_dir=chroot
overlay_dir=../overlay

# Package lists
package_list=()
package_removal_list=()

# Clean chroot dir and make sure folder is not mounted
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true
rm -rf ${chroot_dir}
mkdir -p ${chroot_dir}

# Install the base system into a directory 
debootstrap --arch "${arch}" "${release}" "${chroot_dir}" "${mirror}"

# Use a more complete sources.list file 
cat > ${chroot_dir}/etc/apt/sources.list << EOF
# See http://help.ubuntu.com/community/UpgradeNotes for how to upgrade to
# newer versions of the distribution.
deb ${mirror} ${release} main restricted
# deb-src ${mirror} ${release} main restricted

## Major bug fix updates produced after the final release of the
## distribution.
deb ${mirror} ${release}-updates main restricted
# deb-src ${mirror} ${release}-updates main restricted

## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team. Also, please note that software in universe WILL NOT receive any
## review or updates from the Ubuntu security team.
deb ${mirror} ${release} universe
# deb-src ${mirror} ${release} universe
deb ${mirror} ${release}-updates universe
# deb-src ${mirror} ${release}-updates universe

## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team, and may not be under a free licence. Please satisfy yourself as to
## your rights to use the software. Also, please note that software in
## multiverse WILL NOT receive any review or updates from the Ubuntu
## security team.
deb ${mirror} ${release} multiverse
# deb-src ${mirror} ${release} multiverse
deb ${mirror} ${release}-updates multiverse
# deb-src ${mirror} ${release}-updates multiverse

## N.B. software from this repository may not have been tested as
## extensively as that contained in the main release, although it includes
## newer versions of some applications which may provide useful features.
## Also, please note that software in backports WILL NOT receive any review
## or updates from the Ubuntu security team.
deb ${mirror} ${release}-backports main restricted universe multiverse
# deb-src ${mirror} ${release}-backports main restricted universe multiverse

deb ${mirror} ${release}-security main restricted
# deb-src ${mirror} ${release}-security main restricted
deb ${mirror} ${release}-security universe
# deb-src ${mirror} ${release}-security universe
deb ${mirror} ${release}-security multiverse
# deb-src ${mirror} ${release}-security multiverse
EOF

# Mount the temporary API filesystems
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

# Update localisation files
chroot ${chroot_dir} locale-gen en_US.UTF-8
chroot ${chroot_dir} update-locale LANG="en_US.UTF-8"

# Download and update installed packages
chroot ${chroot_dir} apt-get -y update
chroot ${chroot_dir} apt-get -y upgrade 
chroot ${chroot_dir} apt-get -y dist-upgrade

chroot ${chroot_dir} apt-get -y install software-properties-common dctrl-tools

# Install minimal and standard ubuntu packages
add_task minimal standard

case "${PROJECT}" in
    preinstalled-server)
        add_task server

        # Cloud utils
        add_package cloud-init landscape-common

        remove_package cryptsetup needrestart
        ;;
    preinstalled-desktop)
        add_task ubuntu-desktop

        # OEM installer
        add_package oem-config-gtk ubiquity-frontend-gtk
        add_package ubiquity-slideshow-ubuntu language-pack-en-base

        # Audio 
        add_package pulseaudio pavucontrol
        
        # Media playback
        add_package mpv

        # Misc
        add_package dbus-x11

        remove_package cloud-init landscape-common cryptsetup-initramfs
        ;;
esac

# Add tools and firmware
add_package fake-hwclock i2c-tools u-boot-tools mmc-utils flash-kernel wpasupplicant
add_package linux-firmware psmisc wireless-regdb cloud-initramfs-growroot

# Install packages
chroot ${chroot_dir} apt-get install -y "${package_list[@]}"

# Remove packages
chroot ${chroot_dir} apt-get purge -y "${package_removal_list[@]}"

# DNS
echo "nameserver 8.8.8.8" > ${chroot_dir}/etc/resolv.conf

# Create lxd group for default user
chroot ${chroot_dir} addgroup --system --quiet lxd

# Set term for serial tty
mkdir -p ${chroot_dir}/lib/systemd/system/serial-getty@.service.d/
echo "[Service]" > ${chroot_dir}/usr/lib/systemd/system/serial-getty@.service.d/10-term.conf
echo "Environment=TERM=linux" >> ${chroot_dir}/usr/lib/systemd/system/serial-getty@.service.d/10-term.conf

# Use gzip compression for the initrd
echo "COMPRESS=gzip" > ${chroot_dir}/etc/initramfs-tools/conf.d/compression.conf

# Disable apport bug reporting
sed -i 's/enabled=1/enabled=0/g' ${chroot_dir}/etc/default/apport

# Remove release upgrade motd
rm -f ${chroot_dir}/var/lib/ubuntu-release-upgrader/release-upgrade-available
sed -i 's/Prompt=.*/Prompt=never/g' ${chroot_dir}/etc/update-manager/release-upgrades

# Let systemd create machine id on first boot
rm -f ${chroot_dir}/var/lib/dbus/machine-id
true > ${chroot_dir}/etc/machine-id 

# Flash kernel override
(
    echo "Machine: *"
    echo "Kernel-Flavors: any"
    echo "Method: pi"
    echo "Boot-Kernel-Path: /boot/firmware/vmlinuz"
    echo "Boot-Initrd-Path: /boot/firmware/initrd.img"
) > ${chroot_dir}/etc/flash-kernel/db

# Create swapfile on boot
mkdir -p ${chroot_dir}/usr/lib/systemd/system/swap.target.wants/
(
    echo "[Unit]"
    echo "Description=Create the default swapfile"
    echo "DefaultDependencies=no"
    echo "Requires=local-fs.target"
    echo "After=local-fs.target"
    echo "Before=swapfile.swap"
    echo "ConditionPathExists=!/swapfile"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "ExecStartPre=fallocate -l 1GiB /swapfile"
    echo "ExecStartPre=chmod 600 /swapfile"
    echo "ExecStart=mkswap /swapfile"
    echo ""
    echo "[Install]"
    echo "WantedBy=swap.target"
) > ${chroot_dir}/usr/lib/systemd/system/mkswap.service
chroot ${chroot_dir} /bin/bash -c "ln -s ../mkswap.service /usr/lib/systemd/system/swap.target.wants/"

# Swapfile service
(
    echo "[Unit]"
    echo "Description=The default swapfile"
    echo ""
    echo "[Swap]"
    echo "What=/swapfile"
) > ${chroot_dir}/usr/lib/systemd/system/swapfile.swap
chroot ${chroot_dir} /bin/bash -c "ln -s ../swapfile.swap /usr/lib/systemd/system/swap.target.wants/"

case "${PROJECT}" in
    preinstalled-server)
        # Hostname
        echo "ubuntu" > ${chroot_dir}/etc/hostname

        # Hosts file
        (
            echo "127.0.0.1 localhost"
            echo ""
            echo "# The following lines are desirable for IPv6 capable hosts"
            echo "::1 ip6-localhost ip6-loopback"
            echo "fe00::0 ip6-localnet"
            echo "ff00::0 ip6-mcastprefix"
            echo "ff02::1 ip6-allnodes"
            echo "ff02::2 ip6-allrouters"
            echo "ff02::3 ip6-allhosts"
        ) > ${chroot_dir}/etc/hosts

        # Cloud init no cloud config
        (
            echo "# configure cloud-init for NoCloud"
            echo "datasource_list: [ NoCloud, None ]"
            echo "datasource:"
            echo "  NoCloud:"
            echo "    fs_label: system-boot"
        ) > ${chroot_dir}/etc/cloud/cloud.cfg.d/99-fake_cloud.cfg

        # HACK: lower 120 second timeout to 10 seconds
        mkdir -p ${chroot_dir}/etc/systemd/system/systemd-networkd-wait-online.service.d/
        (
            echo "[Service]"
            echo "ExecStart="
            echo "ExecStart=/lib/systemd/systemd-networkd-wait-online --timeout=10"
        ) > ${chroot_dir}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
        ;;
    preinstalled-desktop)
        # Create files/dirs Ubiquity requires
        mkdir -p ${chroot_dir}/var/log/installer
        touch ${chroot_dir}/var/log/installer/debug
        touch ${chroot_dir}/var/log/syslog
        chroot ${chroot_dir} chown syslog:adm /var/log/syslog

        # Create the oem user account
        chroot ${chroot_dir} /usr/sbin/useradd -d /home/oem -G adm,sudo -m -N -u 29999 oem
        chroot ${chroot_dir} /usr/sbin/oem-config-prepare --quiet
        chroot ${chroot_dir} touch /var/lib/oem-config/run

        rm -rf ${chroot_dir}/boot/grub/

        # Hostname
        echo "localhost.localdomain" > ${chroot_dir}/etc/hostname

        # Hosts file
        (
            echo "127.0.0.1	localhost.localdomain	localhost"
            echo "::1		localhost6.localdomain6	localhost6"
            echo ""
            echo "# The following lines are desirable for IPv6 capable hosts"
            echo "::1     localhost ip6-localhost ip6-loopback"
            echo "fe00::0 ip6-localnet"
            echo "ff02::1 ip6-allnodes"
            echo "ff02::2 ip6-allrouters"
            echo "ff02::3 ip6-allhosts"
        ) > ${chroot_dir}/etc/hosts

        # Have plymouth use the framebuffer
        mkdir -p ${chroot_dir}/etc/initramfs-tools/conf-hooks.d
        (
            echo "if which plymouth >/dev/null 2>&1; then"
            echo "    FRAMEBUFFER=y"
            echo "fi"
        ) > ${chroot_dir}/etc/initramfs-tools/conf-hooks.d/plymouth

        # Mouse lag/stutter (missed frames) in Wayland sessions
        # https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/1982560
        (
            echo "MUTTER_DEBUG_ENABLE_ATOMIC_KMS=0"
            echo "MUTTER_DEBUG_FORCE_KMS_MODE=simple"
            echo "CLUTTER_PAINT=disable-dynamic-max-render-time"
        ) >> ${chroot_dir}/etc/environment

        # Enable wayland session
        sed -i 's/#WaylandEnable=false/WaylandEnable=true/g' ${chroot_dir}/etc/gdm3/custom.conf

        # Use NetworkManager by default
        mkdir -p ${chroot_dir}/etc/netplan
        (
            echo "# Let NetworkManager manage all devices on this system"
            echo "network:"
            echo "  version: 2"
            echo "  renderer: NetworkManager"
        ) > ${chroot_dir}/etc/netplan/01-network-manager-all.yaml

        # Networking interfaces
        (
            echo "[main]"
            echo "plugins=ifupdown,keyfile"
            echo "dhcp=internal"
            echo ""
            echo "[ifupdown]"
            echo "managed=true"
            echo ""
            echo "[device]"
            echo "wifi.scan-rand-mac-address=no"
        ) > ${chroot_dir}/etc/NetworkManager/NetworkManager.conf

        # Manage network interfaces
        (
            echo "[keyfile]"
            echo "unmanaged-devices=*,except:type:wifi,except:type:ethernet,except:type:gsm,except:type:cdma"
        ) > ${chroot_dir}/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

        # Disable random wifi mac address
        (
            echo "[connection]"
            echo "wifi.mac-address-randomization=1"
            echo ""
            echo "[device]"
            echo "wifi.scan-rand-mac-address=no"
        ) > ${chroot_dir}/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

        # Disable wifi powersave
        (
            echo "[connection]"
            echo "wifi.powersave = 2"
        ) > ${chroot_dir}/usr/lib/NetworkManager/conf.d/20-override-wifi-powersave-disable.conf
        ;;
esac

# Clean package cache
chroot ${chroot_dir} apt-get -y autoremove
chroot ${chroot_dir} apt-get -y clean
chroot ${chroot_dir} apt-get -y autoclean

# Umount temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

# Tar the entire rootfs
cd ${chroot_dir} && XZ_OPT="-3 -T0" tar -cpJf "../ubuntu-${RELASE_VERSION}-${PROJECT}-arm64.rootfs.tar.xz" . && cd ..
