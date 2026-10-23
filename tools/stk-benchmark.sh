#!/usr/bin/env bash
# SuperTuxKart's built-in benchmark on the TV, run from this computer over
# SSH, for numbers that compare across kernels, Mesa builds and settings:
#   1. Installs supertuxkart (Arch Linux ARM's 1.5 has the benchmark).
#   2. Waits for the desktop user (config.sh OMARCHY_USER) to log in at the
#      TV.
#   3. Starts `supertuxkart --benchmark` in that desktop: a replay of the
#      most demanding track, the same every time, at the user's graphics
#      settings. Until it exits, it records every 2 s the temperatures, the
#      fan, the board's power, the CPU's clock and load, and the GPU's clock.
#   4. Prints the game's result (frames, time, and its steady, mostly stable
#      and typical frame rates), the biggest stages of its CPU profile per
#      frame, and a summary of the recording.
# The game exits by itself, after a few minutes at a few frames per second.
#
# Usage: tools/stk-benchmark.sh <the SHIELD's address>
source "$(dirname "$0")/../scripts/lib.sh"
need ssh

host=${1:-}
[[ -n $host ]] || die "usage: $0 <the SHIELD's address>"
user=$OMARCHY_USER

log "supertuxkart, on $(on_shield 'uname -r -v')"
on_shield 'pacman -S --needed --noconfirm supertuxkart >/dev/null'
uid=$(on_shield "id -u $user") || die "no user $user on the SHIELD: run scripts/20-install-omarchy.sh"

log "waiting for $user to log in at the TV"
until on_shield "pgrep -u $user -x quickshell >/dev/null && ls /run/user/$uid/hypr/*/.socket.sock >/dev/null 2>&1"; do
  sleep 5
done
# Let the desktop settle: the shell, its plugins, the wallpaper
sleep 15

log "the benchmark, on the TV, and the recording"
on_shield "cat > /run/darcy-stk-sampler.sh && chmod +x /run/darcy-stk-sampler.sh" <<'EOF'
#!/bin/bash
# One line every 2 s until supertuxkart has come and gone (or 20 minutes)
fan= ina=
for h in /sys/class/hwmon/hwmon*; do
  case $(cat $h/name) in
    pwmfan) fan=$h ;;
    ina3221) ina=$h ;;
  esac
done
read -r _ u n s i w q sq _ < /proc/stat
prev_busy=$((u + n + s + q + sq)) prev_total=$((u + n + s + i + w + q + sq))
seen=false
for (( t = 0; t < 1200; t += 2 )); do
  sleep 2
  read -r _ u n s i w q sq _ < /proc/stat
  busy=$((u + n + s + q + sq)) total=$((u + n + s + i + w + q + sq))
  load=$(( 100 * (busy - prev_busy) / (total - prev_total) ))
  prev_busy=$busy prev_total=$total
  running=0
  pgrep -x supertuxkart >/dev/null && { running=1; seen=true; }
  temps=$(for z in /sys/class/thermal/thermal_zone*; do echo -n "$(sed 's/-thermal//' $z/type)=$(( $(cat $z/temp) / 1000 )) "; done)
  echo "running=$running ${temps}fan=$([[ -n $fan ]] && cat $fan/fan1_input) power=$([[ -n $ina ]] && echo $(( $(cat $ina/in3_input) * $(cat $ina/curr3_input) / 1000 ))) cpu_mhz=$(( $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq) / 1000 )) load=$load gpu_mhz=$(( $(cat /sys/class/devfreq/57000000.gpu/cur_freq) / 1000000 ))"
  $seen && (( ! running )) && break
done
exit 0
EOF
on_shield "rm -f /run/darcy-stk-samples.txt; systemctl reset-failed darcy-stk-sampler 2>/dev/null
  systemd-run --quiet --unit=darcy-stk-sampler -p StandardOutput=file:/run/darcy-stk-samples.txt /run/darcy-stk-sampler.sh
  sig=\$(ls -t /run/user/$uid/hypr/ | head -1)
  runuser -u $user -- env XDG_RUNTIME_DIR=/run/user/$uid HYPRLAND_INSTANCE_SIGNATURE=\$sig \
    hyprctl dispatch 'hl.dsp.exec_cmd(\"sh -c \\\"supertuxkart --benchmark > /tmp/stk-benchmark.log 2>&1\\\"\")' >/dev/null"
start=$SECONDS
until on_shield "pgrep -u $user -x supertuxkart >/dev/null"; do
  ((SECONDS - start < 60)) || die "supertuxkart didn't start: see /tmp/stk-benchmark.log on the SHIELD"
  sleep 2
done
log "running; it exits by itself"
while on_shield "pgrep -u $user -x supertuxkart >/dev/null" 2>/dev/null || (($? == 255)); do
  sleep 10
done
on_shield 'systemctl stop darcy-stk-sampler 2>/dev/null' || true

log "the result"
on_shield "python3 - /home/$user/.config/supertuxkart/config-0.10 /run/darcy-stk-samples.txt" <<'EOF' >&2
import csv, glob, os, re, sys
d, samples = sys.argv[1], sys.argv[2]
newest = lambda pattern: max(glob.glob(os.path.join(d, pattern)), key=os.path.getmtime)
report = list(csv.reader(open(newest("stdout.log.perf-report-*.csv"))))
frames, ms = int(report[1][0]), int(report[1][1])
print(f"    {frames} frames in {ms / 1000:.0f} s: {1000 * frames / ms:.1f} FPS on average")
print("    steady, mostly stable, typical FPS: " + ", ".join(x.strip() for x in report[4][:3]))
settings = dict(zip((x.strip() for x in report[6][1:]), (x.strip() for x in report[7][1:])))
print(f"    at {settings.get('Resolution width')}x{settings.get('Resolution height')}, "
      f"dynamic lighting {settings.get('Dynamic lighting')}, shadows {settings.get('Shadow Resolution')}")
lines = open(newest("stdout.log.profile-*-cpu-0.csv")).read().splitlines()
names = [n.strip().strip('"') for n in lines[0].lstrip("#").split(",") if n.strip()]
rows = [[float(x) for x in l.split(",") if x.strip()] for l in lines[51:] if l.strip()]
if rows:
    n = min(len(names), min(len(r) for r in rows))
    avg = sorted(((sum(r[i] for r in rows) / len(rows), names[i]) for i in range(n)), reverse=True)
    print("    CPU time per frame, the biggest stages:")
    for us, name in avg[:6]:
        print(f"      {us / 1000:7.1f} ms  {name}")
vals = {}
for line in open(samples):
    if "running=1" not in line:
        continue
    for k, v in re.findall(r"(\w+)=(\d+)", line):
        vals.setdefault(k, []).append(int(v))
if vals:
    gpu = vals.get("gpu_mhz", [])
    top = max(gpu) if gpu else 0
    mean = lambda k: sum(vals[k]) / len(vals[k]) if vals.get(k) else 0
    print(f"    while it ran ({len(gpu)} samples): power {mean('power') / 1000:.1f} W on average, "
          f"CPU load {mean('load'):.0f}%, GPU at {top} MHz {100 * gpu.count(top) // max(1, len(gpu))}% of the time")
    print("    hottest: " + ", ".join(f"{k} {max(vals[k])} C" for k in ("cpu", "gpu", "mem") if k in vals))
EOF
