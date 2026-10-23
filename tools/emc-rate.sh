#!/usr/bin/env bash
# The SHIELD's memory clock (EMC), over SSH: show it, or move it to one of
# the rates in the table U-Boot hands the kernel (NOTES.md B7). Needs
# kernel #18 or later, with the tegra210-emc module loaded.
#   status   the rate, its PLL, the table's rates, the DRAM's temperature
#            state (MR4: 0-3 nominal refresh, 4 2x, 5 4x, 6-7 throttle)
#   <Hz>     a rate from the table. The clock framework keeps the rate it
#            last set, so a raised floor (debugfs emc/min_rate) moves it up
#            and a lowered ceiling (max_rate) moves it down, and the full
#            range is restored after. A timer reboots the SHIELD 3 minutes
#            later unless the switch came back, in case it hangs where the
#            lockup detectors don't reach.
# Not kept across reboots: the SHIELD boots at the 800 MHz cboot leaves.
#
# Usage: tools/emc-rate.sh <the SHIELD's address> status|<Hz>
source "$(dirname "$0")/../scripts/lib.sh"
need ssh

host=${1:-}
what=${2:-}
[[ -n $host && ( $what == "status" || $what =~ ^[0-9]+$ ) ]] ||
  die "usage: $0 <the SHIELD's address> status|<Hz>"

on_shield 'mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
  [ -e /sys/kernel/debug/emc/available_rates ]' ||
  die "no EMC driver on the SHIELD: kernel #18 or later, and modprobe tegra210-emc"

status='d=/sys/kernel/debug/emc c=/sys/kernel/debug/clk/emc
  echo "    $(cat $c/clk_rate) Hz from $(cat $c/clk_parent); DRAM temperature state $(cat $d/temperature)"
  echo "    rates: $(cat $d/available_rates)"'

if [[ $what == "status" ]]; then
  on_shield "$status" >&2
  exit 0
fi

on_shield "grep -qw $what /sys/kernel/debug/emc/available_rates" ||
  die "$what Hz isn't in the table: see $0 $host status"

log "the EMC to $what Hz (the SHIELD reboots in 3 minutes if this hangs)"
on_shield "systemctl reset-failed darcy-emc-rollback 2>/dev/null
  systemd-run --quiet --unit=darcy-emc-rollback --on-active=180 /bin/sh -c 'echo b > /proc/sysrq-trigger'
  d=/sys/kernel/debug/emc c=/sys/kernel/debug/clk/emc
  lo=\$(cut -d' ' -f1 \$d/available_rates)
  hi=\$(tr ' ' '\n' < \$d/available_rates | tail -1)
  sync
  cur=\$(cat \$c/clk_rate)
  if [ $what -gt \$cur ]; then
    echo $what > \$d/min_rate && echo \$lo > \$d/min_rate
  elif [ $what -lt \$cur ]; then
    echo $what > \$d/max_rate && echo \$hi > \$d/max_rate
  fi"
on_shield 'systemctl stop darcy-emc-rollback.timer'
on_shield "$status" >&2
on_shield "[ \$(cat /sys/kernel/debug/clk/emc/clk_rate) = $what ]" || die "the EMC isn't at $what Hz"
