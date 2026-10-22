# Pinned inputs for every script in scripts/. Bump a pin here and nowhere else.
# Sourced by scripts/lib.sh; not meant to be run.

# The target: SHIELD TV 2017 (retail P2897, board P2894). Scripts refuse to
# talk to any device whose product name differs.
SHIELD_PRODUCT=darcy
SHIELD_ADB_PORT=5555

# NVIDIA's stock firmware, the undo button. Download it yourself from
# https://developer.nvidia.com/tools-downloads (search "SHIELD Android TV 2017
# Recovery"). It needs a free NVIDIA developer login and is not ours to
# redistribute, so only its checksum lives here.
RECOVERY_TITLE="NVIDIA SHIELD ANDROID TV 2017 Recovery OS Image"
RECOVERY_VERSION=9.1.1
RECOVERY_FILE=nv-recovery-image-shield-2017-atv-9.1.1.tgz
RECOVERY_SHA256=31e72d6c1aa838de19a43e738845036e99f3c7c464b83f14942577a40c7fa16d

# Android boot image header for what we hand cboot, copied from NVIDIA's own
# 9.1.1 recovery.img, the stock image that carries a ramdisk
# (unpack_bootimg --format=mkbootimg). The offsets are NVIDIA's base of
# 10000000 *decimal* plus the usual 0x8000/0x1000000/0x100, which is not a
# DRAM address, so cboot evidently places kernel and ramdisk itself.
BOOTIMG_ARGS=(
  --header_version 1 --pagesize 2048
  --os_version 11.0.0 --os_patch_level 2022-04
  --base 0 --kernel_offset 0x00991680 --ramdisk_offset 0x01989680 --tags_offset 0x00989780
)

# What cboot accepts (fastboot getvar on darcy, bootloader 32.00.2019.50):
# "fastboot boot" downloads at most 32 MiB, and the boot and recovery
# partitions hold 0x1980000 bytes (25.5 MiB). Every boot image must fit the
# partition, so U-Boot + FIT payload stay under 25.5 MiB.
FASTBOOT_MAX_DOWNLOAD=$((0x2000000))
BOOTIMG_MAX_SIZE=$((0x1980000))

# Size of the dummy ramdisk in a probe boot image (scripts/06 --probe). The
# default is about the largest FIT payload that still fits BOOTIMG_MAX_SIZE;
# override it in the environment to probe cboot with a smaller ramdisk.
PROBE_RAMDISK_SIZE=${PROBE_RAMDISK_SIZE:-$((24 * 1024 * 1024))}

# Third-party sources, fetched into vendor/<name> by scripts/03-fetch-sources.sh.
# Format: name|git url|commit
SOURCES=(
  # NVIDIA's downstream darcy device trees (hardware reference), as mirrored by LineageOS
  "lineage-t210-foster|https://github.com/LineageOS/android_hardware_nvidia_platform_t210_foster|df8bb6647ef9535f5fedf89f9c1850deaf433465"
  "lineage-t210-common|https://github.com/LineageOS/android_hardware_nvidia_platform_t210_common|66dbf4e2fd9689217c94e713b2cec004a02af759"
  # LineageOS SHIELD boot chain: cboot -> this U-Boot -> kernel, plus the device configs that build it
  "lineage-u-boot|https://github.com/LineageOS/android_hardware_nvidia_u-boot|0b3cd412eadc0c7ec321eb410d8701fa19854839"
  "lineage-device-foster|https://github.com/LineageOS/android_device_nvidia_foster|aa1bf701c00a4febfd64a91ddc82b4a5af600b53"
  "lineage-device-t210-common|https://github.com/LineageOS/android_device_nvidia_t210-common|c2c9cd3f3c3971af110a2a4d2cd7878b74fdec6d"
  # Community aarch64 port of Omarchy, installed onto a running Arch Linux ARM
  "omarchy-arm|https://github.com/alexisraitano-myffu/omarchy-arm|579f15c699dab01e2b3b12e2c4d2503873359be9"
)

# Host packages (Arch Linux / Omarchy, x86_64)
HOST_PACKAGES=(
  base-devel git curl avahi bc swig python-pyelftools python-setuptools
  android-tools            # adb, fastboot, mkbootimg, unpack_bootimg
  dtc                      # dtc, fdtget
  uboot-tools              # mkimage
  aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils
  qemu-user-static qemu-user-static-binfmt arch-install-scripts
)
