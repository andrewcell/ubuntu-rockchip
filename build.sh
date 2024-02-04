#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")"

usage() {
cat << HEREDOC
Usage: $0 --board=[orangepi-5] --release=[jammy|mantic] --release=[preinstalled-desktop|preinstalled-server]

Required arguments:
  -b, --board=BOARD      target board 
  -r, --release=RELEASE  ubuntu release
  -p, --project=PROJECT  ubuntu project

Optional arguments:
  -h,  --help            show this help message and exit
  -c,  --clean           clean the build directory
  -d,  --docker          use docker to build
  -k,  --kernel-only     only compile the kernel
  -u,  --uboot-only      only compile uboot
  -ro, --rootfs-only     only build rootfs
  -so, --server-only     only build server image
  -do, --desktop-only    only build desktop image
  -m,  --mainline        use mainline linux sources
  -l,  --launchpad       use kernel and uboot from launchpad repo
  -v,  --verbose         increase the verbosity of the bash script
HEREDOC
}

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")"

for i in "$@"; do
    case $i in
        -h|--help)
            usage
            exit 0
            ;;
        -b=*|--board=*)
            export BOARD="${i#*=}"
            shift
            ;;
        -b|--board)
            export BOARD="${2}"
            shift 2
            ;;
        -r=*|--release=*)
            export RELEASE="${i#*=}"
            shift
            ;;
        -r|--release)
            export RELEASE="${2}"
            shift 2
            ;;
        -p=*|--project=*)
            export PROJECT="${i#*=}"
            shift
            ;;
        -p|--project)
            export PROJECT="${2}"
            shift 2
            ;;
        -d|--docker)
            DOCKER="docker run --privileged --network=host --rm -it -v \"$(pwd)\":/opt -e BOARD -e VENDOR -e LAUNCHPAD -e MAINLINE -e SERVER_ONLY -e DESKTOP_ONLY -e KERNEL_ONLY -e UBOOT_ONLY ubuntu-rockchip-build /bin/bash"
            docker build -t ubuntu-rockchip-build docker
            shift
            ;;
        -k|--kernel-only)
            export KERNEL_ONLY=Y
            shift
            ;;
        -u|--uboot-only)
            export UBOOT_ONLY=Y
            shift
            ;;
        -ro|--rootfs-only)
            export ROOTFS_ONLY=Y
            shift
            ;;
        -do|--desktop-only)
            export DESKTOP_ONLY=Y
            shift
            ;;
        -so|--server-only)
            export SERVER_ONLY=Y
            shift
            ;;
        -m|--mainline)
            export KERNEL_TARGET=mainline
            shift
            ;;
        -l|--launchpad)
            export LAUNCHPAD=Y
            shift
            ;;
        -c|--clean)
            export CLEAN=Y
            ;;
        -v|--verbose)
            set -x
            shift
            ;;
        -*)
            echo "Error: unknown argument \"$i\""
            exit 1
            ;;
        *)
            ;;
    esac
done

if [[ "${KERNEL_TARGET}" != "mainline" ]]; then
    export KERNEL_TARGET=bsp
fi

if [ "${BOARD}" == "help" ]; then
    for file in config/boards/*; do
        basename "${file%.conf}"
    done
    exit 0
fi

if [ "${RELEASE}" == "help" ]; then
    for file in config/releases/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ "${PROJECT}" == "help" ]; then
    for file in config/projects/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

# No board param passed
if [ -z "${BOARD}" ] || [ -z "${RELEASE}" ] || [ -z "${PROJECT}" ]; then
    usage
    exit 1
fi

# Clean the build directory
if [[ ${CLEAN} == "Y" ]]; then
    if [ -d build/rootfs ]; then
        umount -lf build/rootfs/dev/pts 2> /dev/null || true
        umount -lf build/rootfs/* 2> /dev/null || true
    fi
    rm -rf build
fi

# Read board configuration files
while :; do
    for file in config/boards/*; do
        if [ "${BOARD}" == "$(basename "${file%.conf}")" ]; then
            # shellcheck source=/dev/null
            set -o allexport && source "${file}" && set +o allexport
            break 2
        fi
    done
    echo "Error: \"${BOARD}\" is an unsupported board"
    exit 1
done

# Read release configuration files
while :; do
    for file in config/releases/*; do
        if [ "${RELEASE}" == "$(basename "${file%.sh}")" ]; then
            # shellcheck source=/dev/null
            source "${file}"
            break 2
        fi
    done
    echo "Error: \"${RELEASE}\" is an unsupported release"
    exit 1
done

# Read project configuration files
while :; do
    for file in config/projects/*; do
        if [ "${PROJECT}" == "$(basename "${file%.sh}")" ]; then
            # shellcheck source=/dev/null
            source "${file}"
            break 2
        fi
    done
    echo "Error: \"${PROJECT}\" is an unsupported project"
    exit 1
done

# Start logging the build process
mkdir -p build/logs && exec > >(tee "build/logs/build-$(date +"%Y%m%d%H%M%S").log") 2>&1

# Build only the Linux kernel then exit
if [[ ${KERNEL_ONLY} == "Y" ]]; then
    eval "${DOCKER}" ./scripts/build-kernel.sh
    exit 0
fi

# Build only U-Boot then exit
if [[ ${UBOOT_ONLY} == "Y" ]]; then
    eval "${DOCKER}" ./scripts/build-u-boot.sh
    exit 0
fi

# Build only the rootfs then exit
if [[ ${ROOTFS_ONLY} == "Y" ]]; then
    eval "${DOCKER}" ./scripts/build-rootfs.sh
    exit 0
fi

# Build the Linux kernel if not found
if [[ ${LAUNCHPAD} != "Y" ]]; then
    if [[ ! -e "$(find build/linux-image-*.deb | sort | tail -n1)" || ! -e "$(find build/linux-headers-*.deb | sort | tail -n1)" ]]; then
        eval "${DOCKER}" ./scripts/build-kernel.sh
    fi
fi

# Build U-Boot if not found
if [[ ${LAUNCHPAD} != "Y" ]]; then
    if [[ ! -e "$(find build/u-boot-"${BOARD}"_*.deb | sort | tail -n1)" ]]; then
        eval "${DOCKER}" ./scripts/build-u-boot.sh
    fi
fi

# Create the root filesystem
eval "${DOCKER}" ./scripts/build-rootfs.sh

# Create the disk image
eval "${DOCKER}" ./scripts/config-image.sh

exit 0
