# Brief: installing omarchy-arm on darcy (SHIELD TV 2017, Tegra210)

**Analysis only.** Don't change files or touch the device. Cite `file:line`
(omarchy-arm at `~/projects/nvidia/vendor/omarchy-arm`, pinned commit
579f15c). Say plainly what is a guess.

## State (measured today)

Arch Linux ARM on a USB NVMe SSD (root `PARTLABEL=darcy-root`), booted
cboot → U-Boot → our mainline 7.2.11 (FIT with its own initramfs; the
rootfs's mkinitcpio/limine are not in the boot chain). Kernel #13 has our
nouveau and tegra-drm fixes; nouveau loads at boot; `mesa-darcy` (Mesa
26.2.5 + tegra driver patches, provides mesa/opengl-driver) replaces
ALARM's mesa. Plain Hyprland 0.56.2 runs on the TV (`tools/hyprland-try.sh`:
user alarm, console 7, `AQ_DRM_DEVICES=/dev/dri/by-path/platform-50000000.host1x-card`,
`cursor:no_hardware_cursors = 1`, no blur/shadows/animations); keyboard
works. Network: **Wi-Fi only** (no switch for Ethernet), iwd + systemd-networkd
(DHCP), SSH key-only (`PasswordAuthentication no`). Root's SSH key is the
only way in besides the TV and a USB keyboard. Our own units: the thermal
guard (`darcy-thermal-guard.service`), a watchdog drop-in. New user
`devsecai` (wheel, temporary password) for Omarchy.

The dry run (`install.sh --dry-run --profile generic-aarch64` as devsecai)
is at
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/omarchy-dryrun-1.txt`.

## What I found and plan

1. `install/hardware/network.sh` disables iwd and systemd-networkd;
   `install/config/enable-services.sh` enables NetworkManager (+ resolved,
   sddm, docker.socket, cups, avahi, power-profiles-daemon, oomd). Only
   enabled, not started, so SSH survives the install, but after the reboot
   NetworkManager has no profile for the Wi-Fi. Plan: write
   `/etc/NetworkManager/system-connections/<ssid>.nmconnection` from
   `/var/lib/iwd/<ssid>.psk` before rebooting; find the SHIELD afterwards by
   mDNS (avahi + nss-mdns) in case NetworkManager's DHCP gets another lease.
2. A `tegra` platform as a patch to omarchy-arm: `bin/omarchy-hw-platform`
   (darcy's compatible is `nvidia,p2894-0050-a08 nvidia,darcy
   nvidia,tegra210`), a new `bin/omarchy-hw-tegra`, `install.sh` (help and
   the platform case), `install/hardware/arm/vulkan.sh` (no packages:
   no Mesa Vulkan driver for Tegra), a new `install/hardware/arm/tegra.sh`
   run from `install/hardware/all.sh`, `default/hypr/platform.lua` + a new
   `default/hypr/platform/tegra.lua` (Pi-like light look plus the software
   cursor), and the same for SDDM's greeter (`/usr/share/sddm/hyprland.lua`).
   aquamarine already skips nouveau's card as "not a KMS device", so I plan
   no `AQ_DRM_DEVICES` (please check that conclusion).
3. Then the real install as devsecai with `-y`, sudo through a temporary
   NOPASSWD drop-in that I remove afterwards, then a reboot into SDDM.

## Questions

1. What else in this install can cut remote access or break the boot on
   this machine (network, resolved and `/etc/resolv.conf`, nsswitch, ufw
   or docker firewall rules, sshd, sudoers, logind, the SDDM autostart,
   plymouth, zram, oomd, systemd-boot or mkinitcpio hooks, anything that
   assumes an x86/EFI box)? Point at the files.
2. Is my NetworkManager hand-over right (keyfile format, permissions, the
   iwd backend vs wpa_supplicant on brcmfmac, MAC randomisation, DHCP client
   id)? Anything to keep iwd's or networkd's DHCP lease or address?
3. Review the tegra platform plan against the code: anything missing,
   especially for SDDM's greeter (how it starts Hyprland, which config,
   environment) and for omarchy's own runtime checks of the platform.
4. Anything in the package set that is a bad idea on 3 GB RAM / Tegra210
   for a first install (docker, chromium, clang), that `install.sh` lets us
   leave out cleanly, and how.

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-omarchy-ncodex.md`
and reply with only that path.
