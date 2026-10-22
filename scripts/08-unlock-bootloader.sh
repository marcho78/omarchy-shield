#!/usr/bin/env bash
# Unlock the SHIELD's bootloader so it boots our images.
#
# THIS ERASES ANDROID'S USER DATA: apps, accounts and settings. Android itself
# stays and boots afterwards, and NVIDIA's recovery image (scripts/04) restores
# everything stock.
#
# Before running:
#   - the computer on the SHIELD's USB port farthest from HDMI, USB debugging
#     allowed (scripts/07 must have worked)
#   - a SHIELD controller with a USB cable in the port near HDMI: the
#     bootloader asks for confirmation on the TV (X/Y move, A selects), and
#     it has no Bluetooth, so the remote does not work there
#
# Afterwards: finish Android setup, turn Developer options, USB debugging and
# Network debugging back on, and run scripts/07 to see "unlocked: yes".
#
# Usage: CONFIRM_UNLOCK=yes scripts/08-unlock-bootloader.sh
source "$(dirname "$0")/lib.sh"
need adb fastboot

[[ ${CONFIRM_UNLOCK:-} == yes ]] || die "this erases Android's user data on the SHIELD.
  To go ahead, run: CONFIRM_UNLOCK=yes $0"
[[ -f $ROOT/recovery/$RECOVERY_VERSION/flash-all.sh ]] ||
  die "unpack NVIDIA's recovery image first (scripts/04-unpack-recovery.sh): it is the way back"

serial=$(adb devices | awk '$2 == "device" && $1 !~ /:/ { print $1; exit }')
[[ -n $serial ]] ||
  die "no authorized SHIELD on USB: use the port farthest from HDMI and allow USB debugging"
device=$(adb -s "$serial" shell getprop ro.product.device | tr -d '\r')
[[ $device == "$SHIELD_PRODUCT" ]] || die "the USB device is '$device', not '$SHIELD_PRODUCT'"

log "rebooting the SHIELD into its bootloader"
adb -s "$serial" reboot bootloader
fb=""
for i in $(seq 60); do
  fb=$(fastboot devices | awk '{ print $1; exit }')
  [[ -n $fb ]] && break
  sleep 2
done
[[ -n $fb ]] || die "fastboot sees nothing; unplug the SHIELD's power to return to Android"

if fastboot -s "$fb" getvar unlocked 2>&1 | grep -q 'unlocked: yes'; then
  log "already unlocked; rebooting to Android"
  fastboot -s "$fb" reboot || true
  exit 0
fi

log "asking the bootloader to unlock: CONFIRM ON THE TV with the controller"
fastboot -s "$fb" oem unlock || warn "the bootloader returned an error (see above)"

log "the SHIELD now erases user data and restarts into Android setup; this takes a few minutes"
log "then: Developer options > USB debugging and Network debugging on, and run scripts/07-check-fastboot.sh"
