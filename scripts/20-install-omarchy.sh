#!/usr/bin/env bash
# Install Omarchy on a SHIELD that runs the installed system, over SSH: the
# omarchy-arm port at config.sh's pin with patches/omarchy-arm on top (the
# Tegra210 platform), for the desktop user config.sh names (OMARCHY_USER).
#   1. The user: created when missing, in wheel, with a temporary password
#      (OMARCHY_PASSWORD, the user name if unset); passwd changes it. SSH
#      takes keys only, so the password counts at the TV alone.
#   2. Wi-Fi through the switch: Omarchy moves networking from iwd and
#      systemd-networkd to NetworkManager at the next boot. Each network iwd
#      knows (/var/lib/iwd/*.psk) gets a NetworkManager profile first, so the
#      SHIELD comes back on Wi-Fi. The secrets stay on the SHIELD.
#   3. omarchy-arm, reset to its pin and patched, goes to the user's home,
#      and its install.sh runs as the user in a service (it outlives a dropped
#      SSH session), with sudo needing no password for that user meanwhile.
#      With --dry-run, install.sh only prints its plan, and steps 1-2 are
#      shown, not done.
#   4. Nothing reboots: NetworkManager and the SDDM login screen take over
#      at the next boot.
#
# Needs SSH as root with device-info/ssh/id_ed25519 (scripts/13).
#
# Usage: scripts/20-install-omarchy.sh [--dry-run] <the SHIELD's address>
source "$(dirname "$0")/lib.sh"
need ssh tar git

dry_run=false
if [[ ${1:-} == --dry-run ]]; then
  dry_run=true
  shift
fi
host=${1:-}
[[ -n $host ]] || die "usage: $0 [--dry-run] <the SHIELD's address>"
[[ -f $ROOT/device-info/ssh/id_ed25519 ]] ||
  die "no device-info/ssh/id_ed25519: scripts/13 makes it, with the root filesystem"

user=$OMARCHY_USER
src=$ROOT/vendor/omarchy-arm
[[ -d $src/.git ]] || die "no vendor/omarchy-arm: run scripts/03-fetch-sources.sh"

log "omarchy-arm at $(source_commit omarchy-arm), with patches/omarchy-arm/"
git -C "$src" -c advice.detachedHead=false checkout -q -f "$(source_commit omarchy-arm)"
git -C "$src" clean -q -fd
for p in "$ROOT"/patches/omarchy-arm/*.patch; do
  git -C "$src" apply --whitespace=nowarn "$p"
done

if $dry_run; then
  on_shield "id $user >/dev/null 2>&1" || warn "would create the user $user (wheel, temporary password)"
  on_shield 'for f in /var/lib/iwd/*.psk; do [ -e "$f" ] && echo "    would give NetworkManager the network $(basename "$f" .psk)"; done' >&2
else
  log "the user $user"
  on_shield "id $user >/dev/null 2>&1 || { useradd -m -G wheel -s /bin/bash $user &&
    echo '$user:${OMARCHY_PASSWORD:-$user}' | chpasswd && echo created; }"

  log "NetworkManager profiles for the Wi-Fi networks iwd knows"
  on_shield 'bash -s' <<'EOF'
set -eu
d=/etc/NetworkManager/system-connections
install -d -m 700 "$d"
for f in /var/lib/iwd/*.psk; do
  [ -e "$f" ] || continue
  ssid=$(basename "$f" .psk)
  # iwd names a network with an odd SSID "=<hex>"; leave those to the user
  case $ssid in =*) echo "skipping $ssid: set it up in NetworkManager"; continue ;; esac
  psk=$(sed -n 's/^Passphrase=//p' "$f")
  [ -n "$psk" ] || psk=$(sed -n 's/^PreSharedKey=//p' "$f")
  [ -n "$psk" ] || { echo "skipping $ssid: no key in $f"; continue; }
  umask 077
  cat > "$d/$ssid.nmconnection" <<NM
[connection]
id=$ssid
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$ssid

[wifi-security]
key-mgmt=wpa-psk
psk=$psk

[ipv4]
method=auto

[ipv6]
method=auto
NM
  chmod 600 "$d/$ssid.nmconnection"
  echo "    $ssid"
done
EOF
fi

log "the checkout in /home/$user/omarchy-arm"
tar -C "$ROOT/vendor" -cf - --exclude=.git omarchy-arm |
  on_shield "rm -rf /home/$user/omarchy-arm && tar -xf - -C /home/$user --no-same-owner &&
    chown -R $user: /home/$user/omarchy-arm"

flags=-y
$dry_run && flags=--dry-run
log "install.sh $flags as $user (the log: /home/$user/omarchy-install.log)"
sudoers=/etc/sudoers.d/99-darcy-omarchy-install
on_shield "echo '$user ALL=(ALL) NOPASSWD: ALL' > $sudoers && chmod 440 $sudoers"
trap 'on_shield "rm -f $sudoers" || warn "remove $sudoers on the SHIELD by hand"' EXIT
# A logind session (PAMName) gives it the user's runtime directory and manager
on_shield "systemctl reset-failed darcy-omarchy-install 2>/dev/null; systemd-run --quiet --unit=darcy-omarchy-install \
  --uid=$user -p PAMName=login --working-directory=/home/$user/omarchy-arm \
  -p StandardOutput=file:/home/$user/omarchy-install.log -p StandardError=inherit /home/$user/omarchy-arm/install.sh $flags"
while :; do
  sleep 30
  status=0
  on_shield 'systemctl is-active --quiet darcy-omarchy-install' || status=$?
  ((status == 0)) && continue
  # 255: no SSH (the SHIELD's Wi-Fi drops now and then); ask again
  ((status == 255)) || break
done
on_shield "tail -n 12 /home/$user/omarchy-install.log" >&2 || true
on_shield "grep -q -E 'Dry run complete|Omarchy is installed|==> Done' /home/$user/omarchy-install.log" ||
  die "install.sh didn't finish (above: the end of /home/$user/omarchy-install.log)"
if $dry_run; then
  log "dry run done"
else
  log "installed; reboot the SHIELD (systemctl reboot) for NetworkManager and the login screen"
fi
