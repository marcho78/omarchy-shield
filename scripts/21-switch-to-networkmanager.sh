#!/usr/bin/env bash
# Switch the SHIELD from iwd and systemd-networkd to NetworkManager before
# the first Omarchy boot, with a way back. scripts/20 installs NetworkManager
# and its profiles, and Omarchy only enables it for the next boot; Wi-Fi is
# the only link, so the switch is tried live first:
#   1. On the SHIELD, a timer puts iwd and networkd back in 2 minutes unless
#      the switch is confirmed, and a service stops them and starts
#      NetworkManager (and avahi, for darcy.local).
#   2. This computer waits for SSH at the same address (the profile asks for
#      networkd's lease) or at darcy.local, then confirms.
#   3. A report: the connection, the address, the route, DNS.
# Nothing reboots. Without a confirmation the SHIELD is back on iwd and
# networkd 2 minutes after the switch, at its old address.
#
# Needs SSH as root with device-info/ssh/id_ed25519 (scripts/13).
#
# Usage: scripts/21-switch-to-networkmanager.sh <the SHIELD's address>
source "$(dirname "$0")/lib.sh"
need ssh

host=${1:-}
[[ -n $host ]] || die "usage: $0 <the SHIELD's address>"

on_shield 'command -v nmcli >/dev/null && ls /etc/NetworkManager/system-connections/*.nmconnection >/dev/null 2>&1' ||
  die "no NetworkManager or no profile on the SHIELD: run scripts/20-install-omarchy.sh first"
on_shield 'systemctl is-active --quiet NetworkManager' && { log "the SHIELD is on NetworkManager already"; exit 0; }

log "switching to NetworkManager (iwd and networkd come back in 2 minutes unless confirmed)"
on_shield 'rm -f /run/darcy-nm-ok; systemctl reset-failed darcy-nm-switch darcy-nm-rollback 2>/dev/null
  systemd-run --quiet --unit=darcy-nm-rollback --on-active=120 /bin/sh -c \
    "[ -e /run/darcy-nm-ok ] || { systemctl stop NetworkManager; systemctl start systemd-networkd iwd; }"
  systemd-run --quiet --unit=darcy-nm-switch /bin/sh -c \
    "sleep 2; systemctl stop iwd systemd-networkd systemd-networkd.socket; systemctl start NetworkManager avahi-daemon"'

log "waiting for the SHIELD at $host or darcy.local"
reached=
start=$SECONDS
while ((SECONDS - start < 100)); do
  sleep 5
  for h in "$host" darcy.local; do
    if host=$h on_shield 'systemctl is-active --quiet NetworkManager && touch /run/darcy-nm-ok' 2>/dev/null; then
      reached=$h
      break 2
    fi
  done
done
[[ -n $reached ]] ||
  die "no SSH through NetworkManager: the SHIELD goes back to iwd and networkd, at $host, within 2 minutes of the switch"
host=$reached
on_shield 'systemctl stop darcy-nm-rollback.timer'
log "on NetworkManager, reached at $host"
on_shield 'nmcli -t -f DEVICE,STATE,CONNECTION device | grep -v -E ":unmanaged|^lo:" | sed "s/^/    /"
  ip -4 -br addr show wlan0 | sed "s/^/    /"
  ip route show default | sed "s/^/    /"
  resolvectl query archlinux.org 2>&1 | head -1 | sed "s/^/    DNS: /"' >&2
