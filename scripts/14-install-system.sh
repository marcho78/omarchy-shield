#!/usr/bin/env bash
# Install the system on the SHIELD, from its bootloader menu (fastboot):
#   - build/rootfs.simg (scripts/13) goes into the userdata partition, in
#     place of Android's user data
#   - build/boot-uboot-darcy-system.img (scripts/12 --system) goes into the
#     boot partition, so that the SHIELD starts U-Boot and the system instead
#     of Android. Android must not start again while the system is on
#     userdata: it would find a filesystem it cannot use there, offer to
#     wipe it, and put its own recovery back.
#
# The bootloader partitions, the partition table, the recovery slot and
# Android's system and vendor partitions stay as they are. NVIDIA's recovery
# image undoes this: its flash-all.sh puts Android's boot partition back, and
# Android then offers to wipe the user data.
#
# Usage: CONFIRM_FLASH=yes scripts/14-install-system.sh
source "$(dirname "$0")/lib.sh"
need fastboot

rootfs="$ROOT/build/rootfs.simg"
boot="$ROOT/build/boot-uboot-darcy-system.img"
[[ -f $rootfs ]] || die "build the root filesystem first: scripts/13-make-rootfs.sh"
[[ -f $boot ]] || die "build the system payload first: scripts/12-make-payload.sh --system"
size=$(stat -c %s "$boot")
((size <= BOOTIMG_MAX_SIZE)) || die "${boot#"$ROOT"/} is $size bytes; the boot partition holds $BOOTIMG_MAX_SIZE"

[[ ${CONFIRM_FLASH:-} == yes ]] || die "this replaces Android's boot partition and its user data.
  To go ahead, run: CONFIRM_FLASH=yes $0"

fb=$(fastboot devices | awk '{ print $1; exit }')
[[ -n $fb ]] || die "the SHIELD is not in its bootloader: run scripts/07-check-fastboot.sh --stay"
state=$(timeout 15 fastboot -s "$fb" getvar unlocked 2>&1) ||
  die "the bootloader does not answer: unplug the SHIELD's power, get back to the bootloader menu and run this again"
grep -q 'unlocked: [Yy]es' <<<"$state" || die "the bootloader is locked: run scripts/08-unlock-bootloader.sh first"
# cboot calls itself t210ref in fastboot; the device tree it names tells the board
dtb=$(timeout 15 fastboot -s "$fb" oem dtbname 2>&1 | grep -o '[^ ]*\.dtb' || true)
[[ $dtb == *"-$SHIELD_PRODUCT-"* ]] || die "the device in fastboot is not a $SHIELD_PRODUCT (its bootloader names '${dtb:-no device tree}')"

# The filesystem image must fit the partition (it grows to fill it on the first boot)
part=$(timeout 15 fastboot -s "$fb" getvar partition-size:userdata 2>&1 | sed -n 's/^partition-size:userdata: *//p')
if [[ $part =~ ^0x[0-9a-fA-F]+$ ]]; then
  need_bytes=$(stat -c %s "${rootfs%.simg}.img")
  ((need_bytes <= part)) || die "the root filesystem ($need_bytes bytes) does not fit userdata ($((part)) bytes)"
else
  warn "fastboot reports no size for userdata; flashing anyway"
fi

log "writing the root filesystem to userdata"
timeout 1200 fastboot -s "$fb" flash userdata "$rootfs" || die "writing userdata failed"
log "writing U-Boot and the system to boot"
timeout 300 fastboot -s "$fb" flash boot "$boot" || die "writing boot failed"

log "installed. On the TV, choose 'Continue' in the bootloader menu (or run: fastboot reboot)."
