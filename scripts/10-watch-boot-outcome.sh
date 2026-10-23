#!/usr/bin/env bash
# After choosing "Boot recovery kernel": watch USB and print how the SHIELD
# came back. With no console on the TV, that is how our U-Boot reports:
#
#   bootloader  back in the bootloader menu: U-Boot ran, cboot reported no
#               framebuffer
#   android     rebooted into Android: U-Boot ran, the framebuffer cboot
#               reported was unusable
#   none        no reboot within the time limit: U-Boot's console is on the
#               TV, or it hung, or recovery was not chosen. Look at the TV.
#
# Start it while the SHIELD sits in the bootloader menu (after scripts/09).
# Read-only: it only lists USB devices and asks fastboot for one variable.
#
# Usage: scripts/10-watch-boot-outcome.sh [seconds]   (default 180)
source "$(dirname "$0")/lib.sh"
need fastboot

limit=${1:-180}

start=$(nvidia_usb)
log "watching USB for ${limit}s (now $start)"
for ((t = 0; t < limit; t += 2)); do
  now=$(nvidia_usb)
  if [[ $now != "$start" ]]; then
    case $now in
      *:b43d) echo android; exit 0 ;;
      *:b442) if timeout 5 fastboot getvar unlocked > /dev/null 2>&1; then
                echo bootloader
                exit 0
              fi ;;
    esac
  fi
  sleep 2
done
echo none
