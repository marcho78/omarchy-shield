#!/bin/bash
# What the SHIELD's power management is doing, read-only. Run on it over SSH:
#
#   ssh root@<address> 'bash -s [<seconds>]' < tools/power-status.sh
#
# CPU idle (driver, and how often and how long each core sleeps), CPU
# frequency (driver, governor, rates, the clock the cores run on), the DFLL
# and its PWM pin, the cooling devices, then temperatures, fan, power and the
# CPU rate every 10 s for <seconds> (default: one reading), with the share of
# that time each core spent asleep.
set -u
secs=${1:-0}
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
dbg=/sys/kernel/debug
cpu=/sys/devices/system/cpu

echo "$(uname -rv), up $(cut -d. -f1 /proc/uptime) s"
grep -q 'cpuidle.off=1' /proc/cmdline && echo "cpuidle.off=1 is on the command line"

echo "cpuidle: driver $(cat $cpu/cpuidle/current_driver 2>/dev/null || echo none), governor $(cat $cpu/cpuidle/current_governor 2>/dev/null || echo none)"
for s in $cpu/cpu[0-9]*/cpuidle/state*; do
  [[ -d $s ]] || continue
  c=${s#$cpu/}
  echo "  ${c%%/*} $(cat $s/name): entered $(cat $s/usage) times, $(( $(cat $s/time) / 1000000 )) s in all, rejected $(cat $s/rejected), too long $(cat $s/above), too short $(cat $s/below), disabled $(cat $s/disable)"
done

policies=$(ls -d $cpu/cpufreq/policy* 2>/dev/null)
[[ -n $policies ]] || echo "cpufreq: no policy"
for p in $policies; do
  echo "cpufreq ${p##*/}: driver $(cat $p/scaling_driver), governor $(cat $p/scaling_governor), CPUs $(cat $p/related_cpus), now $(cat $p/scaling_cur_freq) kHz, allowed $(cat $p/scaling_min_freq)-$(cat $p/scaling_max_freq) kHz of $(cat $p/cpuinfo_min_freq)-$(cat $p/cpuinfo_max_freq)"
  echo "  rates (kHz): $(cat $p/scaling_available_frequencies 2>/dev/null)"
  [[ -r $p/stats/time_in_state ]] && echo "  time at each rate (kHz 10ms): $(tr '\n' ' ' < $p/stats/time_in_state)"
done
echo "cclk_g: from $(cat $dbg/clk/cclk_g/clk_parent 2>/dev/null || echo ?) at $(cat $dbg/clk/cclk_g/clk_rate 2>/dev/null || echo ?) Hz"
d=$dbg/tegra_dfll_fcpu
if [[ -d $d ]]; then
  echo "DFLL: enabled $(cat $d/enable), locked $(cat $d/lock), rate $(cat $d/rate) Hz"
else
  echo "DFLL: no driver"
fi
for g in $dbg/pinctrl/*.pinmux/pinconf-groups; do
  [[ -r $g ]] && echo "dvfs_pwm_pbb1 (the CPU rail's PWM): $(sed -n '/(dvfs_pwm_pbb1)/,/function=/p' "$g" | grep -E 'function|tristate' | tr -d '\t' | tr '\n' ' ')"
done

for c in /sys/class/thermal/cooling_device*; do
  echo "cooling ${c##*/} $(cat $c/type): state $(cat $c/cur_state) of $(cat $c/max_state)"
done

fan= ina=
for h in /sys/class/hwmon/hwmon*; do
  case $(cat $h/name) in
    pwmfan) fan=$h ;;
    ina3221) ina=$h ;;
  esac
done
asleep() {
  for c in $cpu/cpu[0-9]*; do
    t=0
    for s in $c/cpuidle/state*; do [[ -r $s/time ]] && t=$(( t + $(cat $s/time) )); done
    echo -n "$t "
  done
}
reading() {
  t=$(for z in /sys/class/thermal/thermal_zone*; do echo -n "$(sed 's/-thermal//' $z/type) $(( $(cat $z/temp) / 1000 ))  "; done)
  f="no fan"; [[ -n $fan ]] && f="fan pwm $(cat $fan/pwm1) $(cat $fan/fan1_input) rpm"
  w="no power monitor"; [[ -n $ina ]] && w="$(( $(cat $ina/in3_input) * $(cat $ina/curr3_input) / 1000 )) mW"
  echo "$(cut -d. -f1 /proc/uptime) s: ${t}°C | $f | $w | CPU $(cat $cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || echo ?) kHz"
}

start=($(asleep)) began=$(date +%s%N)
reading
for (( i = 10; i <= secs; i += 10 )); do
  sleep 10
  reading
done
if (( secs >= 10 )); then
  end=($(asleep)) span=$(( ($(date +%s%N) - began) / 1000 ))
  echo -n "asleep in the last $(( span / 1000000 )) s:"
  for i in "${!end[@]}"; do echo -n " cpu$i $(( (end[i] - start[i]) * 100 / span ))%"; done
  echo
fi
