#!/usr/bin/env bash
# Lock the default root and alarm password logins Arch Linux ARM ships with,
# once the desktop user (config.sh OMARCHY_USER) has a password you chose.
# You confirm that at the start (or CONFIRM_OWN_PASSWORD=yes): a password
# exists, but only you know whose choice it was. Afterwards:
#   - root still logs in over SSH with device-info/ssh/id_ed25519: a locked
#     password doesn't stop a key, as sshd checks the account through PAM
#     (UsePAM yes, checked first)
#   - at the TV, the desktop user logs in, and sudo gives root
#   - systemd's emergency shell, which asks for root's password, won't open
# A timer on the SHIELD unlocks root again after 2 minutes, unless a new SSH
# login proves the key still gets in. By hand, passwd -u root undoes it.
#
# Usage: scripts/22-lock-default-logins.sh <the SHIELD's address>
source "$(dirname "$0")/lib.sh"
need ssh

host=${1:-}
[[ -n $host ]] || die "usage: $0 <the SHIELD's address>"
user=$OMARCHY_USER

log "checks"
[[ $(on_shield "passwd -S $user 2>/dev/null | cut -d' ' -f2") == P ]] ||
  die "$user has no password: scripts/20 sets one, or passwd $user on the SHIELD"
if [[ ${CONFIRM_OWN_PASSWORD:-} != yes ]]; then
  [[ -t 0 ]] || die "run this in a terminal, or with CONFIRM_OWN_PASSWORD=yes"
  read -rp "After this, $user's password is the way in at the TV. Is it one you chose? [y/N] " answer
  [[ $answer == [yY] ]] || die "set $user's password first: passwd $user on the SHIELD"
fi
on_shield "id -nG $user | grep -qw wheel" ||
  die "$user is not in wheel, so it couldn't get root at the TV"
# sshd -T prints each keyword in its own case (UsePAM), older ones in lower case
[[ $(on_shield "sshd -T 2>/dev/null | grep -i '^usepam '" | awk '{print $2}') == yes ]] ||
  die "sshd doesn't use PAM: a locked password would keep root's key out too"

log "root, with an unlock in 2 minutes unless SSH still gets in"
on_shield "systemctl reset-failed darcy-root-unlock 2>/dev/null
  systemd-run --quiet --unit=darcy-root-unlock --on-active=120 /usr/bin/passwd -u root &&
    passwd -l root >/dev/null"
on_shield true ||
  die "no new SSH login: root unlocks again within 2 minutes; look at sshd's log at the TV"
# The unlock stopped, then root checked: the timer may have fired meanwhile
[[ $(on_shield "systemctl stop darcy-root-unlock.timer darcy-root-unlock.service 2>/dev/null
  passwd -S root | cut -d' ' -f2") == L ]] ||
  die "root isn't locked: the unlock may have run first; run this again"

log "alarm"
on_shield "! id alarm >/dev/null 2>&1 || passwd -l alarm >/dev/null"

log "the logins now (L: locked, P: a password)"
on_shield "for u in root alarm $user; do id \$u >/dev/null 2>&1 && passwd -S \$u | cut -d' ' -f1,2; done" |
  sed 's/^/    /' >&2
