# Timeline

The work ran from 2026-10-21 to 2026-10-23, with HDMI audio and fixes on 2026-10-26. The bring-up is 89 commits, a8fab0c to 2c9e98a. The commits after it add the raw data, the login changes, these docs and the later fixes. Times are the commits' own, in US Pacific time. `NOTES.md` has the day-by-day detail.

## Milestones

| When | What happened | Commits |
|---|---|---|
| Oct 21 (committed Oct 22, 00:03) | The SHIELD is surveyed over network adb: model, bootloader, partitions, board revision. NVIDIA's recovery image becomes the safety net. | a8fab0c |
| Oct 22, 00:16–01:14 | U-Boot for the board (target p2894) is built, and the bootloader is unlocked. `fastboot boot` freezes cboot, so test images go in the recovery slot. | a524e39 → b7ddcb2 |
| 01:38–02:11 | Booting Android puts stock recovery back, U-Boot has to be gzipped, and its framebuffer is read from the display controller. **U-Boot's console shows on the TV.** | bbefde2 → fa74230 |
| 02:28–11:14 | First Linux boot: the TV goes black. Suspected first: the PMIC's HDMI power path. Found by four reviewers: Linux's power driver switching off the HDMI encoder's power partition. **Mainline Linux keeps its console on the TV.** | 9547869 → e5503b4 |
| 12:45–13:18 | A test loop that needs no Android: back to fastboot from Linux and from U-Boot. USB works, and the watchdog resets a hung kernel. | 092a153 → d8ac237 |
| 13:29–14:30 | Wi-Fi (BCM4354), Ethernet (RTL8168) and Bluetooth work, Bluetooth after a serial-port alias and a firmware rename. | 6b37865 → a27cdae |
| 15:15–20:05 | The installed system on a USB SSD, with Android left whole. The first cable powered the SSD but carried no data. tegra-drm blanks the TV, so it's kept out for now. **Arch Linux ARM runs, with Wi-Fi and SSH.** | 25fede8 → 2778bdf |
| 20:34–21:45 | Updates go over the network, with nothing to press on the TV. **tegra-drm drives HDMI from boot.** pacman needs Landlock. | 1726fc4 → 31961db |
| 21:46–23:40 | The GPU's first register read froze the board; the fix is to keep its fuse clock on. **nouveau drives the GM20B.** The SHIELD overheats and shuts down: its fan never ran, and the hardware throttle came too late. | 708b4f6 → d4cd616 |
| Oct 23, 00:08–01:18 | CPU power management: idle cores sleep, a thermal guard, and the DFLL, stepped up to stock's 2.0145 GHz. A 10-minute full-load soak levels off at 62 °C. | 7a322c8 → 5575102 |
| 08:16–11:07 | **The GPU draws on the TV.** Mesa's tegra driver needed seven fixes, and the kernel two: stale progress reads, and half-drawn frames. Hyprland runs, and nouveau loads at boot. | bdccfb0 → 648ea26 |
| 11:20–13:57 | **Omarchy installed.** It needed a Tegra210 platform, a firewall-capable kernel, SDDM's last user and a Qt 6.12 colour fix. | ae087db → 54988ed |
| 14:38–17:06 | Performance. At the same settings, SuperTuxKart goes from 17.7 to 37.2 FPS, and runs at 31.3 FPS full screen at 1080p. Two changes did it: nouveau's cache cleaning, fixed in two rounds, and the memory clock, raised from 800 to 1600 MHz with cboot's trained tables. Along the way, two refresh bugs in mainline's memory-clock driver were found and fixed. | f6abea2 → 74115dc |
| 17:54 onward | Whole-system benchmarks. The SSD turns out to be on a USB 2 link. The raw outputs are saved, and the logins changed: a new desktop user picks its password, and the default logins are locked. | 0b5f5c0 onward |
| Oct 26 | **HDMI audio.** The device tree turns the HDMI audio controller on. The TV sending its sound to a soundbar made it seem silent at first. Now on a 4K TV, HDMI 2.0 runs 3840x2160 at 60 Hz. Netflix plays in Chromium (Widevine L3). Uber TV's password prompt works once alarm leaves `wheel`. | after d1a6835 |

## Kernel builds

The number is the kernel's own build counter (`uname -v` shows `#21`). Builds that were never flashed have no entry.

| Build | What it added | Commit |
|---|---|---|
| #7 | Landlock, which pacman's download sandbox needs | 31961db |
| #12 | nouveau reads the GPU's progress from coherent memory (`patches/linux/0004`) | 326afce |
| #13 | tegra-drm waits for nouveau's rendering before a page flip (`0005`) | e841f9b |
| #14 | PSI and zram, for Omarchy's memory handling | f53a3c9 |
| #15 | nf_tables, for Omarchy's firewall and Docker | 47a3653 |
| #16 | nouveau cleans the caches only of buffers the CPU may have written (`0006`, first version) | f6abea2 |
| #18 | The memory-clock driver with cboot's trained tables, review fixes to `0006`, and lockup detectors | 4c8e65b |
| #19 | Hot memory gets refreshed more often, not less (`0007`) | d005f18 |
| #20 | `0006` tracks the pages the CPU writes | d4401c6 |
| #21 | n-codex's fixes to that tracking | 43a9559 |

Earlier builds (the first boots, Wi-Fi, the GPU's fuse clock, the CPU's clocks) went in without a number in their commit messages.

On 2026-10-26 the installed payload got a new device tree (HDMI audio) around #21's kernel, so `uname -v` still shows `#21`.
