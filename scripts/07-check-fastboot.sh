#!/usr/bin/env bash
# Reboot the SHIELD into its bootloader, check that fastboot sees it over USB,
# record what the bootloader reports into device-info/fastboot.txt (lock
# state, board revision), then reboot back to Android. Changes nothing.
#
# Needs a USB-A male-to-male cable from the computer (directly, or through a
# hub or USB-C adapter with USB-A ports) to the SHIELD port farthest from
# HDMI, with "Allow USB debugging" accepted on the TV.
#
# Usage: scripts/07-check-fastboot.sh [--stay]
#   --stay  leave the SHIELD in its bootloader menu, e.g. to check that a USB
#           controller in the port near HDMI can move the highlight and
#           select "Continue" (the unlock confirmation needs exactly that).
#           Unplugging the SHIELD's power also returns to Android.
source "$(dirname "$0")/lib.sh"
need adb fastboot

stay=false
if [[ ${1:-} == --stay ]]; then
  stay=true
fi

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
[[ -n $fb ]] || die "fastboot sees nothing. The SHIELD is in its bootloader menu:
  choose 'Continue' with the controller, or unplug power, to return to Android"
if [[ $fb == *"no permissions"* || $(fastboot devices) == *"no permissions"* ]]; then
  die "no USB permission for fastboot; on Arch: sudo pacman -S android-udev"
fi

out="$ROOT/device-info"
mkdir -p "$out"
{
  fastboot -s "$fb" getvar all
  fastboot -s "$fb" oem dtbname
} > "$out/fastboot.txt" 2>&1 || true
grep -iE 'unlocked|secure|product|version-bootloader|dtb' "$out/fastboot.txt" || true

if $stay; then
  log "left in the bootloader menu: move the highlight with the controller and select"
  log "'Continue' to boot Android, or unplug the SHIELD's power"
  exit 0
fi

log "rebooting back to Android"
# darcy's cboot answers "FAILED (remote: 'unknown reason')" yet restarts
fastboot -s "$fb" reboot ||
  warn "the bootloader reported a failure; it normally restarts anyway. If it stays
  in the bootloader menu, choose 'Continue' with the controller or unplug power."
