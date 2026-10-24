# Shared helpers for scripts/*.sh. Source it; don't run it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config.sh
source "$ROOT/config.sh"
# Your own settings go on top, in config.local.sh, which git ignores. It's
# shell, trusted like config.sh.
if [[ -f $ROOT/config.local.sh ]]; then
  source "$ROOT/config.local.sh"
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The desktop user's name goes into commands run as root on the SHIELD, so
# only a plain account name will do
[[ ${OMARCHY_USER:-} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
  die "OMARCHY_USER '${OMARCHY_USER:-}' is not a plain account name (config.sh, config.local.sh)"
[[ $OMARCHY_USER != root && $OMARCHY_USER != alarm ]] ||
  die "OMARCHY_USER can't be $OMARCHY_USER: the desktop user needs an account of its own"

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

# Runs "$@" on the installed system at $host (the caller's) over SSH as
# root, with the key scripts/13 made
on_shield() {
  ssh -i "$ROOT/device-info/ssh/id_ed25519" -o UserKnownHostsFile="$ROOT/device-info/ssh/known_hosts" \
    -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "root@$host" "$@"
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
