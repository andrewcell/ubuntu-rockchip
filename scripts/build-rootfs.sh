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
chroot_dir=rootfs
overlay_dir=../overlay

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
chroot ${chroot_dir} apt-get -y install dctrl-tools

# Run build rootfs hook to handle project specific changes
if [[ $(type -t build_rootfs_hook__"${PROJECT}") == function ]]; then
    build_rootfs_hook__"${PROJECT}"
fi 

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

# Clean package cache
chroot ${chroot_dir} apt-get -y autoremove
chroot ${chroot_dir} apt-get -y clean
chroot ${chroot_dir} apt-get -y autoclean

# Umount temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

# Tar the entire rootfs
cd ${chroot_dir} && XZ_OPT="-3 -T0" tar -cpJf "../ubuntu-${RELASE_VERSION}-${PROJECT}-arm64.rootfs.tar.xz" . && cd ..
