#!/usr/bin/env bash
# Plain Hyprland on the TV, before Omarchy: run from this computer over SSH.
#   1. Installs hyprland, foot and a font (the root filesystem has none, and
#      foot won't start without one), and loads nouveau (still blocked at
#      boot).
#   2. Writes a minimal config for the stock user "alarm" (Hyprland refuses
#      root): the pointer drawn in software, as Tegra210's cursor plane
#      takes only RGBA8888, and no animations, blur or shadows.
#   3. Starts Hyprland as a service on console 7 with a logind session
#      (PAMName=login), on tegra-drm's card (AQ_DRM_DEVICES), and switches
#      the TV to it. Consoles 1-6 get a login prompt as soon as the TV
#      switches to them, which knocks Hyprland off its console.
# Super+Q opens a terminal, Super+M quits; --stop ends it from here.
#
# Usage: tools/hyprland-try.sh <the SHIELD's address> [--stop]
source "$(dirname "$0")/../scripts/lib.sh"
need ssh

host=${1:-}
[[ -n $host ]] || die "usage: $0 <the SHIELD's address> [--stop]"

if [[ ${2:-} == --stop ]]; then
  on_shield 'systemctl stop darcy-hyprland 2>/dev/null; chvt 1'
  log "Hyprland stopped; the TV is back on console 1"
  exit 0
fi

log "hyprland, foot and a font"
on_shield 'pacman -S --needed --noconfirm hyprland foot ttf-dejavu >/dev/null &&
  { lsmod | grep -q "^nouveau " || modprobe --ignore-install nouveau; }'

log "a minimal config for alarm"
on_shield 'install -d -o alarm -g alarm /home/alarm/.config/hypr &&
  cat > /home/alarm/.config/hypr/hyprland.lua && chown alarm: /home/alarm/.config/hypr/hyprland.lua' <<'EOF'
-- darcy's plain Hyprland (tools/hyprland-try.sh): the smallest config that
-- shows a desktop on the TV. The pointer is drawn in software (Tegra210's
-- cursor plane takes only RGBA8888), and the look costs the GPU as little
-- as it can.
hl.monitor({
    output   = "HDMI-A-1",
    mode     = "1920x1080@60",
    position = "0x0",
    scale    = 1,
})

hl.on("hyprland.start", function ()
    hl.exec_cmd("foot")
end)

hl.config({
    cursor = {
        no_hardware_cursors = 1,
    },
    decoration = {
        rounding = 0,
        shadow   = { enabled = false },
        blur     = { enabled = false },
    },
    animations = {
        enabled = false,
    },
    misc = {
        force_default_wallpaper = 0,
    },
    input = {
        kb_layout = "us",
    },
})

local mainMod = "SUPER"
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd("foot"))
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("hyprctl dispatch 'hl.dsp.exit()'"))
EOF

log "starting Hyprland on console 7"
on_shield 'systemctl stop darcy-hyprland 2>/dev/null; systemctl reset-failed darcy-hyprland 2>/dev/null
  systemd-run --quiet --unit=darcy-hyprland --uid=alarm -p PAMName=login -p TTYPath=/dev/tty7 \
    -p StandardInput=tty -p StandardOutput=journal -p StandardError=journal -p TTYReset=yes -p TTYVHangup=yes \
    -p WorkingDirectory=/home/alarm -E XDG_SESSION_TYPE=wayland -E XDG_CURRENT_DESKTOP=Hyprland \
    -E XDG_SEAT=seat0 -E XDG_VTNR=7 -E AQ_DRM_DEVICES=/dev/dri/by-path/platform-50000000.host1x-card \
    /usr/bin/Hyprland && chvt 7'
sleep 5
on_shield 'systemctl is-active --quiet darcy-hyprland' ||
  die "Hyprland didn't stay up: journalctl -u darcy-hyprland, and /run/user/1000/hypr/*/hyprland.log"
log "Hyprland is on the TV; its log is in /run/user/1000/hypr/*/hyprland.log on the SHIELD"
