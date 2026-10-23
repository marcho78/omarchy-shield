#!/usr/bin/env bash
# Put the files under rootfs/ on a SHIELD that runs the installed system,
# over SSH: the files scripts/13 puts in a new root filesystem. Then systemd
# reloads, and each service under rootfs/etc/systemd/system is enabled and
# restarted. Nothing reboots.
#
# Needs SSH as root with device-info/ssh/id_ed25519 (scripts/13).
#
# Usage: scripts/18-update-files.sh <the SHIELD's address>
source "$(dirname "$0")/lib.sh"
need ssh tar

host=${1:-}
[[ -n $host ]] || die "usage: $0 <the SHIELD's address>"
[[ -f $ROOT/device-info/ssh/id_ed25519 ]] ||
  die "no device-info/ssh/id_ed25519: scripts/13 makes it, with the root filesystem"

units=()
for unit in "$ROOT"/rootfs/etc/systemd/system/*.service; do
  [[ -f $unit ]] && units+=("${unit##*/}")
done

log "copying rootfs/ to the SHIELD at $host"
# Files only: directories that exist there keep their own modes and times
# (systemd keeps / at 555, tmpfiles.d/root.conf)
mapfile -t files < <(cd "$ROOT/rootfs" && find . ! -type d | LC_ALL=C sort)
tar -C "$ROOT/rootfs" --owner=0 --group=0 --numeric-owner --no-recursion -cf - "${files[@]}" |
  on_shield 'tar -xf - -C /'
on_shield "systemctl daemon-reload${units[*]:+ && systemctl enable ${units[*]} && systemctl restart ${units[*]}}"
log "done${units[*]:+; running: ${units[*]}}"
