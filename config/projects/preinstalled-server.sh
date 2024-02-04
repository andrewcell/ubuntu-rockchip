# shellcheck shell=bash

package_list=(
    i2c-tools u-boot-tools mmc-utils flash-kernel wpasupplicant linux-firmware psmisc wireless-regdb cloud-initramfs-growroot
    cloud-init landscape-common
)

package_removal_list=(
    cryptsetup needrestart
)

function build_rootfs_hook__preinstalled-server() {
    local task
    local package
    declare chroot_dir

    # Query list of default ubuntu packages
    for task in minimal standard server; do
        for package in $(chroot "${chroot_dir}" apt-cache dumpavail | grep-dctrl -nsPackage \( -XFArchitecture arm64 -o -XFArchitecture all \) -a -wFTask "${task}"); do
            package_list+=("${package}")
        done
    done

    # Install packages
    chroot "${chroot_dir}" apt-get install -y "${package_list[@]}"

    # Remove packages
    chroot "${chroot_dir}" apt-get purge -y "${package_removal_list[@]}"

    # Hostname
    echo "ubuntu" > "${chroot_dir}/etc/hostname"

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
    ) > "${chroot_dir}/etc/hosts"

    # Cloud init no cloud config
    (
        echo "# configure cloud-init for NoCloud"
        echo "datasource_list: [ NoCloud, None ]"
        echo "datasource:"
        echo "  NoCloud:"
        echo "    fs_label: system-boot"
    ) > "${chroot_dir}/etc/cloud/cloud.cfg.d/99-fake_cloud.cfg"

    # HACK: lower 120 second timeout to 10 seconds
    mkdir -p "${chroot_dir}/etc/systemd/system/systemd-networkd-wait-online.service.d/"
    (
        echo "[Service]"
        echo "ExecStart="
        echo "ExecStart=/lib/systemd/systemd-networkd-wait-online --timeout=10"
    ) > "${chroot_dir}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf"

    return 0
}
