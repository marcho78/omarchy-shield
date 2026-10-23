# Shared helpers for scripts/*.sh. Source it; don't run it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config.sh
source "$ROOT/config.sh"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || die "missing command '$c' (run scripts/00-host-setup.sh)"
  done
}

# The commit config.sh pins for source $1
source_commit() {
  local entry name url commit
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url commit <<<"$entry"
    if [[ $name == "$1" ]]; then
      echo "$commit"
      return
    fi
  done
  die "no source named '$1' in config.sh"
}

# The SHIELD's LAN address: $SHIELD_IP if set, otherwise discovered.
shield_ip() {
  if [[ -n ${SHIELD_IP:-} ]]; then
    echo "$SHIELD_IP"
  else
    "$ROOT/scripts/01-find-shield.sh" --quiet
  fi
}

# NVIDIA's USB device as port:devnum:product, or "none". The product is
# b442 in the bootloader's fastboot, b43d under Android.
nvidia_usb() {
  local d
  for d in /sys/bus/usb/devices/*; do
    if [[ $(cat "$d/idVendor" 2>/dev/null) == 0955 ]]; then
      echo "$(basename "$d"):$(cat "$d/devnum"):$(cat "$d/idProduct")"
      return
    fi
  done
  echo none
}

# Connect network adb to $1 (ip:port), wait for the on-screen approval, and
# refuse anything that is not the pinned SHIELD product.
adb_attach() {
  local target=$1 state="" device i
  adb connect "$target" >/dev/null 2>&1 || true
  for i in $(seq 60); do
    state=$(adb -s "$target" get-state 2>/dev/null || true)
    if [[ $state == device ]]; then
      break
    fi
    if ((i == 1)); then
      log "approve 'Allow network debugging?' on the TV (tick 'Always allow')"
    fi
    sleep 2
  done
  [[ $state == device ]] || die "adb is not authorized on $target"
  device=$(adb -s "$target" shell getprop ro.product.device | tr -d '\r')
  [[ $device == "$SHIELD_PRODUCT" ]] || die "$target is '$device', not '$SHIELD_PRODUCT'; refusing to continue"
}
