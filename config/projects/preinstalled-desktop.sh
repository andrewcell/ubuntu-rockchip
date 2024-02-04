# shellcheck shell=bash

package_list=(
    oem-config-gtk ubiquity-frontend-gtk ubiquity-slideshow-ubuntu language-pack-en-base pulseaudio pavucontrol mpv dbus-x11
    i2c-tools u-boot-tools mmc-utils flash-kernel wpasupplicant linux-firmware psmisc wireless-regdb cloud-initramfs-growroot
)

package_removal_list=(
    cryptsetup-initramfs
)

function build_rootfs_hook__preinstalled-desktop() {
    local task
    local package
    declare chroot_dir

    # Query list of default ubuntu packages
    for task in minimal standard ubuntu-desktop; do
        for package in $(chroot "${chroot_dir}" apt-cache dumpavail | grep-dctrl -nsPackage \( -XFArchitecture arm64 -o -XFArchitecture all \) -a -wFTask "${task}"); do
            package_list+=("${package}")
        done
    done

    # Install packages
    chroot "${chroot_dir}" apt-get install -y "${package_list[@]}"

    # Remove packages
    chroot "${chroot_dir}" apt-get purge -y "${package_removal_list[@]}"

    # Create files/dirs Ubiquity requires
    mkdir -p "${chroot_dir}/var/log/installer"
    chroot "${chroot_dir}" touch /var/log/installer/debug
    chroot "${chroot_dir}" touch /var/log/syslog
    chroot "${chroot_dir}" chown syslog:adm /var/log/syslog

    # Create the oem user account
    chroot "${chroot_dir}" /usr/sbin/useradd -d /home/oem -G adm,sudo -m -N -u 29999 oem
    chroot "${chroot_dir}" /usr/sbin/oem-config-prepare --quiet
    chroot "${chroot_dir}" touch /var/lib/oem-config/run

    rm -rf "${chroot_dir}/boot/grub/"

    # Hostname
    echo "localhost.localdomain" > "${chroot_dir}/etc/hostname"

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
    ) > "${chroot_dir}/etc/hosts"

    # Have plymouth use the framebuffer
    mkdir -p "${chroot_dir}/etc/initramfs-tools/conf-hooks.d"
    (
        echo "if which plymouth >/dev/null 2>&1; then"
        echo "    FRAMEBUFFER=y"
        echo "fi"
    ) > "${chroot_dir}/etc/initramfs-tools/conf-hooks.d/plymouth"

    # Mouse lag/stutter (missed frames) in Wayland sessions
    # https://bugs.launchpad.net/ubuntu/+source/mutter/+bug/1982560
    (
        echo "MUTTER_DEBUG_ENABLE_ATOMIC_KMS=0"
        echo "MUTTER_DEBUG_FORCE_KMS_MODE=simple"
        echo "CLUTTER_PAINT=disable-dynamic-max-render-time"
    ) >> "${chroot_dir}/etc/environment"

    # Enable wayland session
    sed -i 's/#WaylandEnable=false/WaylandEnable=true/g' "${chroot_dir}/etc/gdm3/custom.conf"

    # Use NetworkManager by default
    mkdir -p "${chroot_dir}/etc/netplan"
    (
        echo "# Let NetworkManager manage all devices on this system"
        echo "network:"
        echo "  version: 2"
        echo "  renderer: NetworkManager"
    ) > "${chroot_dir}/etc/netplan/01-network-manager-all.yaml"

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
    ) > "${chroot_dir}/etc/NetworkManager/NetworkManager.conf"

    # Manage network interfaces
    (
        echo "[keyfile]"
        echo "unmanaged-devices=*,except:type:wifi,except:type:ethernet,except:type:gsm,except:type:cdma"
    ) > "${chroot_dir}/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf"

    # Disable random wifi mac address
    (
        echo "[connection]"
        echo "wifi.mac-address-randomization=1"
        echo ""
        echo "[device]"
        echo "wifi.scan-rand-mac-address=no"
    ) > "${chroot_dir}/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf"

    # Disable wifi powersave
    (
        echo "[connection]"
        echo "wifi.powersave = 2"
    ) > "${chroot_dir}/usr/lib/NetworkManager/conf.d/20-override-wifi-powersave-disable.conf"

    return 0
}
