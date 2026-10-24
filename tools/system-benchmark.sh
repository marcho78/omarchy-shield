#!/usr/bin/env bash
# The SHIELD's whole-system numbers, run from this computer over SSH, one
# test at a time so they don't skew each other:
#   - the system: kernel, Mesa, CPU and memory clocks, boot time
#   - idle power and temperatures
#   - CPU: 7-Zip's built-in benchmark (MIPS)
#   - memory: sysbench's read and write bandwidth on all four cores, over
#     64 MiB blocks (well past the CPU's 2 MiB L2, so the DRAM's)
#   - GPU: glmark2's score off-screen (the compositor out of the way), at
#     its default 800x600 and at 1920x1080; needs the desktop user
#     (config.sh OMARCHY_USER) logged in at the TV
#   - storage: fio on the root filesystem: sequential read and write, and
#     random 4 KiB reads, with the USB link the disk is on
#   - Wi-Fi: the link (band, signal, bit rates), and TCP throughput both ways
#     between the SHIELD and this computer, through a firewall rule on the
#     SHIELD that lets only this computer in, on one port, removed after; if
#     this computer is on Wi-Fi too, both links share the air
# Geekbench (public results) is run separately: see NOTES.md B8.
#
# Usage: tools/system-benchmark.sh <the SHIELD's address>
source "$(dirname "$0")/../scripts/lib.sh"
need ssh python3

host=${1:-}
[[ -n $host ]] || die "usage: $0 <the SHIELD's address>"
user=$OMARCHY_USER
port=5201

log "the tools"
on_shield 'pacman -S --needed --noconfirm 7zip sysbench fio glmark2 >/dev/null 2>&1'

log "the system"
on_shield 'mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
  echo "    kernel $(uname -r) $(uname -v | cut -d" " -f1-3)"
  echo "    Mesa $(pacman -Q mesa-darcy 2>/dev/null | cut -d" " -f2)"
  echo "    CPU up to $(( $(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq) / 1000 )) MHz, memory (EMC) at $(( $(cat /sys/kernel/debug/clk/emc/clk_rate) / 1000000 )) MHz"
  echo "    $(systemd-analyze time 2>/dev/null | head -1)"' >&2

# Average board power over $1 seconds, and the hottest zone
power() {
  on_shield "ina=\$(for h in /sys/class/hwmon/hwmon*; do [ \"\$(cat \$h/name)\" = ina3221 ] && echo \$h; done)
    sum=0; for i in \$(seq 1 $1); do sum=\$((sum + \$(cat \$ina/in3_input) * \$(cat \$ina/curr3_input) / 1000)); sleep 1; done
    t=\$(for z in /sys/class/thermal/thermal_zone*; do echo -n \"\$(sed s/-thermal// \$z/type) \$(( \$(cat \$z/temp) / 1000 ))°C  \"; done)
    echo \"    \$(( sum / $1 )) mW; \$t\""
}
log "idle power (20 s)"
power 20 >&2

log "CPU: 7-Zip (all four cores)"
on_shield '7z b 2>/dev/null | grep -E "^(Avr|Tot):" | sed "s/^/    /"' >&2

log "memory bandwidth: sysbench, 4 threads, 64 MiB blocks"
for op in read write; do
  on_shield "sysbench memory --threads=4 --memory-block-size=64M --memory-total-size=64G \
      --memory-oper=$op run 2>/dev/null | sed -n 's/.*(\(.* MiB\/sec\)).*/    $op: \1/p'" >&2
done

log "GPU: glmark2 off-screen (waiting for $user's desktop)"
uid=$(on_shield "id -u $user")
until on_shield "pgrep -u $user -x quickshell >/dev/null && ls /run/user/$uid/hypr/*/.socket.sock >/dev/null 2>&1"; do
  sleep 5
done
for size in 800x600 1920x1080; do
  on_shield "wd=\$(ls /run/user/$uid/ | grep -E '^wayland-[0-9]+\$' | head -1)
    runuser -u $user -- env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=\$wd \
      glmark2-es2-wayland --off-screen --size $size 2>&1 | sed -n 's/.*glmark2 Score: \([0-9]*\).*/    $size: score \1/p'" >&2
done

log "storage: fio on / (1 GiB file, direct I/O)"
on_shield 'd=$(lsblk -no PKNAME $(findmnt -no SOURCE /) | head -1)
  p=$(readlink -f /sys/block/$d/device/../../../..)
  echo "    /dev/$d: $(cat $p/manufacturer 2>/dev/null) $(cat $p/product 2>/dev/null), USB link $(cat $p/speed) Mbit/s"
  f=/var/tmp/darcy-fio.test
  fio --name=w --filename=$f --rw=write --bs=1M --size=1G --direct=1 --ioengine=libaio --iodepth=16 --output-format=terse 2>/dev/null |
    awk -F";" "{printf \"    sequential write: %.0f MB/s\n\", \$48 / 1024}"
  sync; echo 3 > /proc/sys/vm/drop_caches
  fio --name=r --filename=$f --rw=read --bs=1M --size=1G --direct=1 --ioengine=libaio --iodepth=16 --output-format=terse 2>/dev/null |
    awk -F";" "{printf \"    sequential read: %.0f MB/s\n\", \$7 / 1024}"
  fio --name=rr --filename=$f --rw=randread --bs=4k --size=1G --direct=1 --ioengine=libaio --iodepth=32 --runtime=20 --time_based --output-format=terse 2>/dev/null |
    awk -F";" "{printf \"    random 4 KiB read: %.0f IOPS (%.0f MB/s)\n\", \$8, \$7 / 1024}"
  rm -f $f' >&2

log "Wi-Fi: the link, and TCP throughput with this computer"
on_shield 'iw dev wlan0 link | sed -n "s/^\s*\(freq\|signal\|rx bitrate\|tx bitrate\): /    \1: /p"' >&2
me=$(on_shield 'echo $SSH_CLIENT' | cut -d' ' -f1)
on_shield "ufw allow from $me to any port $port proto tcp comment darcy-benchmark >/dev/null"
trap 'on_shield "ufw delete allow from $me to any port $port proto tcp >/dev/null" || warn "remove the ufw rule for port $port on the SHIELD by hand"' EXIT
# The SHIELD's end: per connection, the first byte says which way the data goes
on_shield "systemd-run --quiet --unit=darcy-tcp-sink --collect /usr/bin/python3 -c '
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((\"\", $port)); s.listen(1)
for _ in range(2):
    c, _ = s.accept(); way = c.recv(1)
    if way == b\"R\":
        while c.recv(1 << 20): pass
    else:
        buf = bytes(1 << 20); end = time.time() + 10
        while time.time() < end: c.sendall(buf)
    c.close()
'"
sleep 2
python3 - "$host" "$port" <<'EOF' >&2
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
def run(way):
    c = socket.create_connection((host, port)); c.sendall(way)
    n, start = 0, time.time()
    if way == b"R":
        buf = bytes(1 << 20)
        while time.time() - start < 10:
            c.sendall(buf); n += len(buf)
        c.shutdown(socket.SHUT_WR); c.recv(1)
    else:
        while True:
            b = c.recv(1 << 20)
            if not b: break
            n += len(b)
    t = time.time() - start; c.close()
    return n * 8 / t / 1e6
print(f"    to the SHIELD: {run(b'R'):.0f} Mbit/s")
print(f"    from the SHIELD: {run(b'S'):.0f} Mbit/s")
EOF
