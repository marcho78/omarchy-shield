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
  # Linux, the stable release Arch Linux ARM's linux-aarch64 ships (v7.2.11)
  "linux|https://github.com/gregkh/linux|a2de78ee6ed8bf8cd99d177c74865a6e8c3cb6ea"
  # Community aarch64 port of Omarchy, installed onto a running Arch Linux ARM
  "omarchy-arm|https://github.com/alexisraitano-myffu/omarchy-arm|579f15c699dab01e2b3b12e2c4d2503873359be9"
)

# Firmware the payload's kernel loads, from upstream repositories at pinned
# commits. scripts/12 fetches each file into vendor/firmware/<repo>/, checks
# its sha256 and puts it in the initramfs under /lib/firmware.
# Format: name|git url|commit
FIRMWARE_REPOS=(
  "linux-firmware|https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git|2627913c0f298b6b2f4206e3bdabec5ed90c9a52"
  "wireless-regdb|https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git|389b9b702cf9018e9a9078ccc4fa8eaae2e054e3"
)
# Format: repo|path|sha256
FIRMWARE=(
  # Microcode of the XUSB (USB host) controller
  "linux-firmware|nvidia/tegra210/xusb.bin|941873a6a70993b5c40a608cedc4608c281458c11949092d4bce125b96a92025"
  # PHY patch for the RTL8168g Ethernet chip (r8169, XID 4c0)
  "linux-firmware|rtl_nic/rtl8168g-2.fw|f878ec719f78e0b104bc73362a9862611858bec893f58a1b3b289a0a57d71d25"
  # Wi-Fi regulatory database (cfg80211) and its signature
  "wireless-regdb|regulatory.db|7e236caecd939c8ec98be4870bf30422f28ffef2565a38aaaa2d9ddabd0c2641"
  "wireless-regdb|regulatory.db.p7s|50332f0db09b8bcc719235ec4985c27377f2cc2f42abb7b5dcf951866c5a888a"
)

# Firmware from NVIDIA's vendor partition (vendor.img in the recovery image,
# /firmware) that mainline drivers load, and where it goes under
# /lib/firmware. scripts/04 extracts it into recovery/<version>/vendor-firmware/
# and scripts/12 puts it in the initramfs; it is NVIDIA's, so only the names
# live here.
# Format: file in /vendor/firmware|path under /lib/firmware
VENDOR_FIRMWARE=(
  # Wi-Fi (brcmfmac): the BCM4354's firmware, darcy's NVRAM, its CLM blob
  "fw_bcmdhd.bin|brcm/brcmfmac4354-sdio.bin"
  "nvram_darcy_a00.txt|brcm/brcmfmac4354-sdio.txt"
  "bcmdhd_clm_darcy.blob|brcm/brcmfmac4354-sdio.clm_blob"
  # Bluetooth (hci_bcm): the patch for the BCM4354's Bluetooth core. It names
  # itself "BCM4354 37.4MHz Class 1.5 Nvidia-0438", and btbcm names the chip
  # BCM4354 too (subversion 0x610c). bcm4356a3.hcd is the 2019 SHIELD's.
  "bcm4350.hcd|brcm/BCM4354.hcd"
)

# Where the installed system's root filesystem lives; scripts/12 --system
# puts it on the kernel command line:
#   PARTLABEL=darcy-root  a USB disk that scripts/15 writes; Android's
#                         partitions stay as they are, its data included
#   PARTLABEL=UDA         the eMMC's userdata partition, which scripts/14
#                         writes in place of Android's user data
SYSTEM_ROOT=PARTLABEL=darcy-root

# The Wi-Fi regulatory domain (ISO 3166 country code), set by the kernel
# itself (cfg80211.ieee80211_regdom); the image has no iw for Arch's helper
WIFI_COUNTRY=US

# darcy's device tree names the board "nvidia,p2894-0050-a08" (the first
# root compatible), and drivers look for board-specific firmware under that
# name before the generic one: brcm/brcmfmac4354-sdio.nvidia,p2894-0050-a08.bin
BOARD_COMPATIBLE=nvidia,p2894-0050-a08

# Arch Linux ARM's generic aarch64 root filesystem, the base of the system on
# the eMMC (scripts/13). archlinuxarm.org keeps only its latest upload, so a
# newer one stops matching the checksum; scripts/13 still checks its
# signature and prints the checksum to pin.
ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
ALARM_SHA256=42a4eeaa038994ffd31fa173256ef2f0ef511358eeb41b9ea1f8626391b9b319
ALARM_KEY=68B3537F39A313B3E574D06777193F152BDBE6A6  # Arch Linux ARM Build System
# Installed on top of it, after a full upgrade
ROOTFS_PACKAGES=(
  iwd                    # Wi-Fi; systemd-networkd does DHCP, as for Ethernet
  bluez bluez-utils      # bluetoothd, bluetoothctl
  wireless-regdb         # regulatory.db, for cfg80211
  sudo
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
