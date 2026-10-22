#!/usr/bin/env bash
# Boot one of our images through the recovery slot. darcy's cboot answers
# "fastboot boot" with OKAY, then never boots the image and stops answering
# fastboot (power cycle needed), so test images go into the recovery
# partition and start from the bootloader menu's "Recovery mode".
#
# Writes ONLY the recovery partition. Android's normal boot partition is
# untouched, so the SHIELD still boots Android, and --restore puts NVIDIA's
# stock recovery back.
#
# The SHIELD must be in its bootloader (scripts/07-check-fastboot.sh --stay)
# with the bootloader unlocked.
#
# Usage: CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh build/boot-uboot-probe.img
#        CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh --restore
source "$(dirname "$0")/lib.sh"
need fastboot

(($#)) || die "usage: CONFIRM_FLASH=yes $0 <boot image> | --restore"
if [[ $1 == --restore ]]; then
  img="$ROOT/recovery/${RECOVERY_VERSION:?}/recovery.img"
else
  img=$1
fi
[[ -f $img ]] || die "no such image: $img"
size=$(stat -c %s "$img")
((size <= BOOTIMG_MAX_SIZE)) || die "$img is $size bytes; the recovery partition holds $BOOTIMG_MAX_SIZE"

[[ ${CONFIRM_FLASH:-} == yes ]] || die "this writes the SHIELD's recovery partition.
  To go ahead, run: CONFIRM_FLASH=yes $0 $*"

fb=$(fastboot devices | awk '{ print $1; exit }')
[[ -n $fb ]] || die "the SHIELD is not in its bootloader: run scripts/07-check-fastboot.sh --stay"
state=$(timeout 15 fastboot -s "$fb" getvar unlocked 2>&1) ||
  die "the bootloader does not answer (a 'fastboot boot' freezes it): unplug the
  SHIELD's power, get back to the bootloader menu and run this again"
grep -q 'unlocked: [Yy]es' <<<"$state" || die "the bootloader is locked: run scripts/08-unlock-bootloader.sh first"

log "writing ${img#"$ROOT"/} to the recovery partition"
timeout 300 fastboot -s "$fb" flash recovery "$img" ||
  die "flashing failed or timed out; the stock recovery can be put back with --restore"

if [[ $1 == --restore ]]; then
  log "stock recovery restored"
else
  log "on the TV, choose 'Recovery mode' in the bootloader menu (arrow keys + Enter)"
fi
