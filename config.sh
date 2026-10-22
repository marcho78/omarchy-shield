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

# Third-party sources, fetched into vendor/<name> by scripts/03-fetch-sources.sh.
# Format: name|git url|commit
SOURCES=(
  # NVIDIA's downstream darcy device trees (hardware reference), as mirrored by LineageOS
  "lineage-t210-foster|https://github.com/LineageOS/android_hardware_nvidia_platform_t210_foster|df8bb6647ef9535f5fedf89f9c1850deaf433465"
  "lineage-t210-common|https://github.com/LineageOS/android_hardware_nvidia_platform_t210_common|66dbf4e2fd9689217c94e713b2cec004a02af759"
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
