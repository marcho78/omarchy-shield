# Omarchy on the NVIDIA SHIELD TV 2017

A reproducible path to running [Omarchy](https://omarchy.org) (Arch Linux and Hyprland) natively on an NVIDIA SHIELD TV 2017, which uses the Tegra X1. Every step is a script, and every version is pinned. Android stays installed, so you can go back.

The approach:
1. NVIDIA's own bootloader (cboot) starts U-Boot.
2. U-Boot starts a mainline Linux kernel (7.2.11) with a device tree written for this board, and our patches.
3. The kernel boots Arch Linux ARM from a USB SSD. The internal eMMC is an option, in place of Android's data.
4. The community [`omarchy-arm`](https://github.com/alexisraitano-myffu/omarchy-arm) port installs Omarchy on top.

## Status

| Area | State | Notes |
|---|---|---|
| Boot chain | Works | cboot → U-Boot → mainline Linux, with a test loop that needs no Android |
| HDMI | Works | tegra-drm at 1920x1080 from boot |
| USB | Works | The SSD links at USB 2, most likely its cable |
| Wi-Fi | Works | 2.4 and 5 GHz. The signal is weak here, and drops were seen. |
| Ethernet | Driver works | The link hasn't been tested yet (no switch) |
| Bluetooth | Controller works | Pairing a keyboard hasn't been tried yet |
| GPU | Works | OpenGL ES 3.2 through nouveau and our Mesa fixes. No Vulkan. |
| CPU, cooling | Works | Up to stock's 2.0 GHz, idle sleep, the fan, throttling |
| Memory clock | Works, by hand | 1600 MHz like stock, set after each boot; it boots at 800 |
| Omarchy | Works | Hyprland, the login screen, the bar and the lock screen |
| Audio, video playback | Not started | |

## Numbers

All measured on 2026-10-23, kernel #21, memory at 1600 MHz:

| | |
|---|---|
| Geekbench 6 | 317 single-core, 854 multi-core. Stock Android 11 is reported at 302 / 789. |
| SuperTuxKart 1.5 benchmark | 31.3 FPS at 1920x1080 full screen. In a 1054x1054 window, the kernel and memory work took it from 17.7 to 37.2 FPS. |
| glmark2 2023.01 | 847 at 800x600, 288 at 1920x1080 |
| Boot to the login screen | 20.9 s |
| Power | 6.7 W idle, 12.5 W in a game |

[docs/benchmarks.md](docs/benchmarks.md) has every number with its conditions, and `benchmarks/` the raw outputs of our runs.

## Read next

| Document | What's in it |
|---|---|
| [docs/install.md](docs/install.md) | The steps, from a stock SHIELD to Omarchy: what you need, the safety rules, every script |
| [docs/findings.md](docs/findings.md) | What we found, area by area: cause, fix, evidence |
| [docs/problems.md](docs/problems.md) | Constraints, dead ends, claims we corrected, open issues |
| [docs/benchmarks.md](docs/benchmarks.md) | The numbers, how they were measured, against Android |
| [docs/timeline.md](docs/timeline.md) | The work in milestones, and the kernel builds |
| [NOTES.md](NOTES.md) | The day-by-day log, as it was written |
| [research/README.md](research/README.md) | The reviews by other AI agents, and what we used from them |

**Read the safety rules in [docs/install.md](docs/install.md) first.** Unlocking the bootloader erases Android's user data. On the default path, with Linux on a USB SSD, only the boot and recovery partitions are written. The eMMC option also overwrites Android's user data. The board's DTB and bootloader are never written.

## Layout

| Path | What |
|---|---|
| `config.sh` | Every pinned version, commit and checksum |
| `config.local.sh` | Your own settings, such as the desktop user's name. It's shell, read after `config.sh` and trusted like it. Optional, and git ignores it. |
| `scripts/` | The numbered steps; `lib.sh` holds shared helpers |
| `patches/u-boot/` | U-Boot for darcy (target `p2894`). It also passes on cboot's device tree and its trained memory table. |
| `patches/linux/` | Kernel fixes: the GPU's fuse clock, soctherm's throttle, the CPU's top rate, nouveau's progress counter and cache cleaning, tegra-drm's imported buffers, the memory-clock driver's refresh |
| `patches/mesa/` | Mesa's tegra driver fixes: upstream merge request !45355 (0001) and ours (0002-0007) |
| `patches/omarchy-arm/` | omarchy-arm's Tegra210 platform, and the shell's colours under Qt 6.12 |
| `packages/mesa-darcy/` | The Mesa package `scripts/19` builds |
| `kernel/` | The kernel config fragment, our darcy device trees, the FIT description |
| `rootfs/` | Files the installed system gets as they are: the thermal guard |
| `tools/nvblob.py` | Lists and extracts NVIDIA's bootloader packages |
| `tools/darcy-init.c` | The first payload's `/init`: it reports what Linux sees |
| `tools/mmio-read.c`, `tools/pmc-read/` | Read hardware registers, read-only. The power controller's go through the secure monitor. |
| `tools/gpu-power-probe/`, `tools/build-module.sh` | Powers the GPU up step by step, as nouveau does, logging each step. The script builds both kernel modules. |
| `tools/gpu-smoke.c` | The smallest picture a compositor needs (KMS, GBM, EGL, GLES2), printing each step |
| `tools/hyprland-try.sh` | Plain Hyprland on the TV over SSH, before Omarchy |
| `tools/power-status.sh` | Power management at a glance over SSH: CPU idle and clocks, cooling, temperatures, fan, power |
| `tools/emc-table.py`, `tools/emc-rate.sh` | The memory clock: cboot's table as Linux takes it, and moving the rate, with a reboot timer |
| `tools/stk-benchmark.sh`, `tools/system-benchmark.sh` | The benchmarks in `docs/benchmarks.md` |
| `benchmarks/` | The raw output of every benchmark run, with an index |
| `docs/` | The documents above |
| `research/` | The briefs, the agents' reviews, and an index |
| `build/`, `vendor/` | Build output and fetched sources (git-ignored) |
| `device-info/` | Your device snapshot and SSH key (git-ignored; private) |
| `recovery/` | Your unpacked recovery image (git-ignored; NVIDIA's, not redistributable) |

## Credits

- The NVIDIA darcy device tree in mainline Linux (Mark Zhang and Thierry Reding).
- archeYR's mainline port for the 2015 SHIELD, the proven U-Boot chain on a
  SHIELD ([postmarketOS](https://wiki.postmarketos.org/wiki/Nvidia_SHIELD_TV_2015_/_2015_Pro_/_2017_Pro_(nvidia-foster))).
- The LineageOS SHIELD maintainers, for the mirrored NVIDIA sources and the
  model for wrapping U-Boot in a boot image.
- The `omarchy-arm` contributors.
