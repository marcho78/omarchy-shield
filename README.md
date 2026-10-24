<h1 align="center">omarchy-shield</h1>

<p align="center">
  <b>Omarchy on the NVIDIA SHIELD TV 2017, on mainline Linux</b><br>
  A reproducible path from a stock SHIELD to Arch Linux and Hyprland, with every step scripted and every version pinned
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Device: SHIELD TV 2017" src="https://img.shields.io/badge/device-SHIELD%20TV%202017%20(darcy)-informational">
  <img alt="Linux 7.2.11" src="https://img.shields.io/badge/linux-7.2.11%20mainline-informational">
  <img alt="Desktop: Omarchy" src="https://img.shields.io/badge/desktop-Omarchy%20%2B%20Hyprland-informational">
  <img alt="Status: work in progress" src="https://img.shields.io/badge/status-work%20in%20progress-yellow">
</p>

---

## About

[Omarchy](https://omarchy.org) is an Arch Linux and Hyprland setup for x86 PCs. This project runs it natively on the NVIDIA SHIELD TV 2017, a Tegra X1 box. Android stays installed, so you can go back.

The approach:
1. NVIDIA's own bootloader (cboot) starts U-Boot.
2. U-Boot starts a mainline Linux kernel (7.2.11) with a device tree written for this board, and our patches.
3. The kernel boots Arch Linux ARM from a USB SSD. The internal eMMC is an option, in place of Android's data.
4. The community [`omarchy-arm`](https://github.com/alexisraitano-myffu/omarchy-arm) port installs Omarchy on top.

## Highlights

- **Mainline Linux** on a board where it had only a bare device tree. HDMI, USB, Wi-Fi, Bluetooth and Ethernet have drivers running, and so do the GPU, the fan and the CPU's power management.
- **The GPU draws the desktop.** OpenGL ES 3.2 runs through nouveau, with three kernel fixes and seven Mesa patches for Tegra.
- **Stock speeds.** The CPU runs up to 2.0 GHz. The memory reaches 1600 MHz from the timing tables cboot trains at every boot, though for now it's set by hand.
- **Bugs found and fixed along the way**, among them two in mainline's memory-clock driver and one in nouveau's cache handling. The cache fix alone raised a game's frame rate by 80%. The patches are in `patches/`.
- **Ahead of stock Android's reported Geekbench 6 scores.**
- **Reproducible:** 23 numbered scripts, pinned sources and checksums, and the raw output of the benchmark runs.

## Status

| Area | State | Notes |
|---|---|---|
| Boot chain | Works | cboot → U-Boot → mainline Linux, with a test loop that needs no Android |
| HDMI | Works | tegra-drm at 1920x1080 from boot |
| USB | Works | The SSD links at USB 2, most likely because of its cable |
| Wi-Fi | Works | 2.4 and 5 GHz, on NetworkManager |
| Ethernet | Driver works | The link hasn't been tested yet (no switch) |
| Bluetooth | Controller works | Pairing a keyboard hasn't been tried yet |
| GPU | Works | OpenGL ES 3.2 through nouveau and our Mesa fixes. No Vulkan. |
| CPU, cooling | Works | Up to stock's 2.0 GHz, idle sleep, the fan, throttling |
| Memory clock | Works, set by hand | 1600 MHz like stock after `tools/emc-rate.sh`; it boots at 800 |
| Omarchy | Works | Hyprland, the login screen, the bar and the lock screen |
| Audio, video playback | Not started | |

## Benchmarks

Measured on 2026-10-23, kernel #21, memory at 1600 MHz:

| Test | Result |
|---|---|
| Geekbench 6 | **317** single-core, **854** multi-core ([result](https://browser.geekbench.com/v6/cpu/19382032)). Stock Android 11 is reported at 302 / 789. |
| SuperTuxKart 1.5 benchmark | **31.3 FPS** at 1920x1080 full screen. In a 1054x1054 window, the kernel and memory work took it from 17.7 to 37.2 FPS. |
| glmark2 2023.01 | 847 at 800x600, 288 at 1920x1080 |
| Memory bandwidth | 20.6 GB/s write, 10.2 GB/s read |
| Boot to the login screen | 20.9 s |
| Power | 6.7 W idle, 12.5 W in a game |

[docs/benchmarks.md](docs/benchmarks.md) gives every number with its conditions. `benchmarks/` keeps the raw outputs.

## Quick start

Read [docs/install.md](docs/install.md) first. It has what you need, the safety rules and every command. The steps come in four stages:

| Stage | Scripts | What happens |
|---|---|---|
| Prepare | `00`–`04` | Host tools; find and survey the SHIELD; fetch the sources; unpack NVIDIA's recovery image, the safety net |
| Boot chain | `05`–`10` | Build U-Boot; check fastboot; unlock the bootloader (this erases Android's user data); test from the recovery slot |
| System | `11`–`18` | Build the kernel and its payload; build the root filesystem; write the USB SSD; install; update over the network |
| Desktop | `19`–`22` | Mesa for the GPU; Omarchy; NetworkManager; lock the default logins |

> [!WARNING]
> On the default path, only the boot and recovery partitions are written. Never flash `dtb`, the bootloader blob, BCT, TOS, EKS or the partition table: a bad DTB has bricked SHIELDs before. Only the SHIELD TV 2017 (`darcy`) is supported, and the scripts refuse other boards.

## Documentation

| Document | What's in it |
|---|---|
| [docs/install.md](docs/install.md) | The steps, from a stock SHIELD to Omarchy |
| [docs/findings.md](docs/findings.md) | What we found, area by area: cause, fix, evidence |
| [docs/lessons.md](docs/lessons.md) | Constraints, what went wrong and how it was fixed, claims we corrected |
| [docs/benchmarks.md](docs/benchmarks.md) | The numbers, how they were measured, against Android |
| [docs/timeline.md](docs/timeline.md) | The work in milestones, and the kernel builds |
| [NOTES.md](NOTES.md) | The day-by-day engineering log |
| [research/README.md](research/README.md) | Reviews by other AI agents, and what we used from them |

<details>
<summary><b>Repository layout</b></summary>

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
| `tools/` | Diagnostics and benchmarks: register readers, a GPU power-up probe, a minimal GPU test, power and memory-clock tools, the benchmark scripts |
| `benchmarks/` | The raw outputs of our benchmark runs, with an index |
| `docs/` | The documents above |
| `research/` | The briefs, the agents' reviews, and an index |
| `build/`, `vendor/` | Build output and fetched sources (git-ignored) |
| `device-info/` | Your device snapshot and SSH key (git-ignored; private) |
| `recovery/` | Your unpacked recovery image (git-ignored; NVIDIA's, not redistributable) |

</details>

## Contributing

Contributions are welcome: code, testing on your own SHIELD TV 2017, documentation, and problem reports. The open work is in the status table above: audio, video playback, Bluetooth pairing, the memory clock at boot. Sending the fixes upstream is open too. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to report a problem and how to make a change: safety first, reproducible steps, evidence for every number.

## Disclaimer

This is an independent community project. It isn't affiliated with or endorsed by NVIDIA, Omarchy or omarchy-arm. NVIDIA and SHIELD are trademarks of NVIDIA Corporation. Unlocking and flashing can leave a device unusable: follow the safety rules, and proceed at your own risk.

## License

This project's own files are under the [MIT license](LICENSE), with these exceptions:
- **GPL-2.0, as their SPDX headers say:** the device trees in `kernel/dts/`, `tools/mmio-read.c`, `tools/pmc-read/` and `tools/gpu-power-probe/`.
- **`patches/`:** each patch carries the license of the project it applies to. That's GPL-2.0 for Linux and U-Boot, and MIT for Mesa and omarchy-arm.
- **NVIDIA's firmware and recovery image** aren't included. The scripts take them from your own download.

## Credits

- The NVIDIA darcy device tree in mainline Linux (Mark Zhang and Thierry Reding).
- archeYR's mainline port for the 2015 SHIELD, the proven U-Boot chain on a SHIELD ([postmarketOS](https://wiki.postmarketos.org/wiki/Nvidia_SHIELD_TV_2015_/_2015_Pro_/_2017_Pro_(nvidia-foster))).
- The LineageOS SHIELD maintainers, for the mirrored NVIDIA sources and the model for wrapping U-Boot in a boot image.
- The [`omarchy-arm`](https://github.com/alexisraitano-myffu/omarchy-arm) contributors, and [Omarchy](https://omarchy.org) itself.
