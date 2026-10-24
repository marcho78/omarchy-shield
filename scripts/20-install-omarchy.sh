#!/usr/bin/env bash
# Install Omarchy on a SHIELD that runs the installed system, over SSH: the
# omarchy-arm port at config.sh's pin with patches/omarchy-arm on top (the
# Tegra210 platform), for the desktop user config.sh names (OMARCHY_USER).
#   1. The user: created when missing, in wheel, with the password typed at
#      the start (twice, hidden). It reaches the SHIELD through SSH's input,
#      never a command line. A user already there keeps its password, unless
#      it has none (a run cut off between creating it and setting one). SSH
#      takes keys only, so the password counts at the TV alone.
#   2. Wi-Fi through the switch: Omarchy moves networking from iwd and
#      systemd-networkd to NetworkManager at the next boot. Each network iwd
#      knows (/var/lib/iwd/*.psk) gets a NetworkManager profile first, so the
#      SHIELD comes back on Wi-Fi, with the permanent MAC and networkd's DHCP
#      client ID, so the router hands out the same address. The secrets stay
#      on the SHIELD. scripts/21 tries the switch before any reboot.
#   3. omarchy-arm, reset to its pin and patched, goes to the user's home,
#      and its install.sh runs as the user in a service (it outlives a dropped
#      SSH session), with sudo needing no password for that user meanwhile.
#      With --dry-run, install.sh only prints its plan, and steps 1-2 are
#      shown, not done. The checkout still goes to the SHIELD, and install.sh
#      runs there with the same temporary sudo rule.
#   4. SDDM's last user: its Omarchy theme logs in as that user, and
#      omarchy-arm records one only in its first-boot setup, which this
#      skips.
#   5. A report: sshd, the firewall's SSH and mDNS rules, and the network
#      services the next boot starts. Nothing reboots: NetworkManager and the
#      SDDM login screen take over at the next boot (scripts/21 first).
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
# The user on the SHIELD: MISSING, SYSTEM (an account below UID 1000), or its
# password state (P usable, L locked, NP none). An SSH failure stops here.
state=$(on_shield "if ! id $user >/dev/null 2>&1; then echo MISSING
  elif [ \$(id -u $user) -lt 1000 ]; then echo SYSTEM
  else passwd -S $user | cut -d' ' -f2; fi")
case $state in
  MISSING|P|L|NP) ;;
  SYSTEM) die "$user is a system account on the SHIELD: choose another OMARCHY_USER" ;;
  *) die "unexpected answer about $user from the SHIELD: '$state'" ;;
esac
# A password for a new user, or for one without a usable password, asked
# before the long part, which then runs by itself
password=
if ! $dry_run && [[ $state != P ]]; then
  [[ -t 0 ]] || die "run this in a terminal: it asks for $user's password"
  while :; do
    IFS= read -rsp "Password for $user on the SHIELD: " password; echo >&2
    IFS= read -rsp "The same again: " again; echo >&2
    [[ -n $password && $password == "$again" ]] && break
    warn "empty, or not the same twice; once more"
  done
  unset again
fi
src=$ROOT/vendor/omarchy-arm
[[ -d $src/.git ]] || die "no vendor/omarchy-arm: run scripts/03-fetch-sources.sh"

log "omarchy-arm at $(source_commit omarchy-arm), with patches/omarchy-arm/"
git -C "$src" -c advice.detachedHead=false checkout -q -f "$(source_commit omarchy-arm)"
git -C "$src" clean -q -fd
for p in "$ROOT"/patches/omarchy-arm/*.patch; do
  git -C "$src" apply --whitespace=nowarn "$p"
done

if $dry_run; then
  on_shield "id $user >/dev/null 2>&1" || warn "would create the user $user (wheel), asking for its password"
  on_shield 'for f in /var/lib/iwd/*.psk; do [ -e "$f" ] && echo "    would give NetworkManager the network $(basename "$f" .psk)"; done' >&2
else
  log "the user $user"
  if [[ -n $password ]]; then
    printf '%s:%s\n' "$user" "$password" |
      on_shield "{ id $user >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash $user; } &&
        chpasswd && echo '    its password is set'" >&2
    unset password
  else
    log "    there already, with a password: it stays"
  fi

  log "NetworkManager profiles for the Wi-Fi networks iwd knows"
  on_shield 'bash -s' <<'EOF'
set -eu
d=/etc/NetworkManager/system-connections
install -d -m 700 "$d"
# networkd's DHCPv4 client ID on the Wi-Fi (RFC 4361: 0xff, IAID, DUID), so
# that NetworkManager asks the router for the same lease
cid=$(networkctl status wlan0 --json=short 2>/dev/null | python3 -c '
import json, sys
c = json.load(sys.stdin).get("DHCPv4Client", {}).get("ClientIdentifier")
print(":".join("%02x" % b for b in c) if c else "")' 2>/dev/null || true)
for f in /var/lib/iwd/*.psk; do
  [ -e "$f" ] || continue
  ssid=$(basename "$f" .psk)
  # iwd names a network with an odd SSID "=<hex>"; leave those to the user
  case $ssid in =*) echo "skipping $ssid: set it up in NetworkManager"; continue ;; esac
  psk=$(sed -n 's/^Passphrase=//p' "$f")
  [ -n "$psk" ] || psk=$(sed -n 's/^PreSharedKey=//p' "$f")
  [ -n "$psk" ] || { echo "skipping $ssid: no key in $f"; continue; }
  case $psk in *\\*) echo "skipping $ssid: its key needs escaping; set it up in NetworkManager"; continue ;; esac
  umask 077
  cat > "$d/$ssid.nmconnection" <<NM
[connection]
id=$ssid
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$ssid
cloned-mac-address=permanent
security=802-11-wireless-security

[wifi-security]
key-mgmt=wpa-psk
psk=$psk

[ipv4]
method=auto
${cid:+dhcp-client-id=$cid}

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
on_shield "echo '$user ALL=(ALL) NOPASSWD: ALL' > $sudoers.new && chmod 440 $sudoers.new &&
  visudo -cqf $sudoers.new && mv $sudoers.new $sudoers"
# The service removes it when it ends, and this does too, in case SSH dropped
trap 'on_shield "rm -f $sudoers" || warn "remove $sudoers on the SHIELD by hand"' EXIT
# A logind session (PAMName) gives it the user's runtime directory and
# manager. The log is emptied here and appended to: systemd reopens a
# service's output for each command, ExecStopPost's included, so truncate:
# would empty it at the end. The last line gives install.sh's exit code.
log_file=/home/$user/omarchy-install.log
on_shield "systemctl reset-failed darcy-omarchy-install 2>/dev/null; rm -f $log_file
  systemd-run --quiet --unit=darcy-omarchy-install --uid=$user -p PAMName=login \
    --working-directory=/home/$user/omarchy-arm -p ExecStopPost=+/usr/bin/rm\ -f\ $sudoers \
    -p StandardOutput=append:$log_file -p StandardError=inherit \
    /bin/sh -c '/home/$user/omarchy-arm/install.sh $flags; echo \"install.sh exit \$?\"'"
while :; do
  sleep 30
  status=0
  on_shield 'systemctl is-active --quiet darcy-omarchy-install' || status=$?
  ((status == 0)) && continue
  # 255: no SSH (the SHIELD's Wi-Fi drops now and then); ask again
  ((status == 255)) || break
done
on_shield "tail -n 12 $log_file" >&2 || true
on_shield "tail -n 1 $log_file | grep -qx 'install.sh exit 0'" ||
  die "install.sh failed (above: the end of $log_file; /var/log/omarchy-install.log has its system steps)"
if $dry_run; then
  log "dry run done"
  exit 0
fi

# The theme's login form has no user field: it takes userModel.lastUser, which
# omarchy-provision-owner writes at a first-boot setup. Without it, SDDM turns
# every password down ("User name not set").
log "SDDM's last user: $user"
on_shield "install -d -m 750 -o sddm -g sddm /var/lib/sddm &&
  printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' $user > /var/lib/sddm/state.conf &&
  chown sddm:sddm /var/lib/sddm/state.conf"

log "what the next boot will run"
on_shield 'for u in sshd NetworkManager systemd-resolved avahi-daemon sddm iwd systemd-networkd; do
    printf "    %-18s %s\n" $u "$(systemctl is-enabled $u 2>/dev/null)"; done
  echo "    firewall: $(ufw status 2>/dev/null | head -1)"
  ufw show added 2>/dev/null | grep -E "22|ssh" | sed "s/^/    /" || echo "    no SSH rule in ufw"
  grep -q "5353" /etc/ufw/before.rules 2>/dev/null && echo "    mDNS (5353) let in" || echo "    no mDNS rule in ufw"
  ls /etc/NetworkManager/system-connections/ | sed "s/^/    NetworkManager profile: /"' >&2
log "installed; next: scripts/21-switch-to-networkmanager.sh, scripts/22-lock-default-logins.sh, then reboot into the login screen"
