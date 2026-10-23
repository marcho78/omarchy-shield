#!/usr/bin/env bash
# Install the system on the SHIELD, from its bootloader menu (fastboot): put
# U-Boot and the system (build/boot-uboot-darcy-system.img, scripts/12
# --system) into the boot partition, so that the SHIELD starts Linux
# instead of Android. Where the root filesystem lives is config.sh
# SYSTEM_ROOT:
#   - PARTLABEL=darcy-root: a USB disk that scripts/15 wrote. Android's
#     partitions stay as they are, its data included, and --restore puts
#     NVIDIA's boot partition back, which starts Android again as it was.
#   - PARTLABEL=UDA: the eMMC's userdata partition, which this also writes
#     (build/rootfs.simg), in place of Android's user data. Android must not
#     start again while Linux is there: it would offer to wipe it.
#
# The bootloader partitions, the partition table and the recovery slot stay
# as they are.
#
# Usage: CONFIRM_FLASH=yes scripts/14-install-system.sh
#        CONFIRM_FLASH=yes scripts/14-install-system.sh --restore
source "$(dirname "$0")/lib.sh"
need fastboot fdtget

restore=false
if [[ ${1:-} == --restore ]]; then
  restore=true
  boot="$ROOT/recovery/$RECOVERY_VERSION/boot.img"
  [[ -f $boot ]] || die "missing $boot: run scripts/04-unpack-recovery.sh"
else
  boot="$ROOT/build/boot-uboot-darcy-system.img"
  [[ -f $boot ]] || die "build the system payload first: scripts/12-make-payload.sh --system"
  # The payload must look for the root filesystem where config.sh says it is
  fdtget "$ROOT/build/system/darcy.dtb" /chosen bootargs | grep -qw -- "root=$SYSTEM_ROOT" ||
    die "build/system was built for another root filesystem: rerun scripts/12-make-payload.sh --system"
  if [[ $SYSTEM_ROOT == PARTLABEL=UDA ]]; then
    rootfs="$ROOT/build/rootfs.simg"
    [[ -f $rootfs ]] || die "build the root filesystem first: scripts/13-make-rootfs.sh"
  fi
fi
size=$(stat -c %s "$boot")
((size <= BOOTIMG_MAX_SIZE)) || die "${boot#"$ROOT"/} is $size bytes; the boot partition holds $BOOTIMG_MAX_SIZE"

if $restore; then
  what="puts NVIDIA's boot partition back (Android starts again)"
elif [[ -n ${rootfs:-} ]]; then
  what="replaces Android's boot partition and its user data"
else
  what="replaces Android's boot partition (its system and data stay)"
fi
[[ ${CONFIRM_FLASH:-} == yes ]] || die "this $what.
  To go ahead, run: CONFIRM_FLASH=yes $0 $*"

fb=$(fastboot devices | awk '{ print $1; exit }')
[[ -n $fb ]] || die "the SHIELD is not in its bootloader: run scripts/07-check-fastboot.sh --stay"
state=$(timeout 15 fastboot -s "$fb" getvar unlocked 2>&1) ||
  die "the bootloader does not answer: unplug the SHIELD's power, get back to the bootloader menu and run this again"
grep -q 'unlocked: [Yy]es' <<<"$state" || die "the bootloader is locked: run scripts/08-unlock-bootloader.sh first"
# cboot calls itself t210ref in fastboot; the device tree it names tells the board
dtb=$(timeout 15 fastboot -s "$fb" oem dtbname 2>&1 | grep -o '[^ ]*\.dtb' || true)
[[ $dtb == *"-$SHIELD_PRODUCT-"* ]] || die "the device in fastboot is not a $SHIELD_PRODUCT (its bootloader names '${dtb:-no device tree}')"

if [[ -n ${rootfs:-} ]]; then
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
fi

log "writing ${boot#"$ROOT"/} to the boot partition"
timeout 300 fastboot -s "$fb" flash boot "$boot" || die "writing boot failed"

if $restore; then
  log "Android's boot partition is back. Choose 'Continue' in the bootloader menu to start Android."
else
  # cboot answers "fastboot reboot" with FAILED (remote: 'unknown reason'), then resets all the same
  log "installed. On the TV, choose 'Continue' in the bootloader menu (or run: fastboot reboot, despite its FAILED)."
fi
