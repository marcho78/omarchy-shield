# Benchmarks

Our numbers come from runs on the SHIELD TV 2017 on 2026-10-23, and `benchmarks/` keeps their raw output. The two exceptions it lists are one run read by hand, and Android's figures, which were reported to us. Unless a section says otherwise, the conditions were:
- Linux 7.2.11 with our patches, kernel build #21
- Mesa 26.2.5 with our tegra fixes
- CPU up to 2014.5 MHz, memory clock (EMC) at 1600 MHz
- the root filesystem on a USB SSD
- Omarchy's desktop logged in and idle

## Against stock Android

| | Linux (ours) | Android 11, stock |
|---|---|---|
| Geekbench 6 single-core | **317** | 302 |
| Geekbench 6 multi-core | **854** | 789 |

- **Our run:** Geekbench 6.7.1, the Linux AArch64 preview, which uploads every result: <https://browser.geekbench.com/v6/cpu/19382032>. The subtests are in `benchmarks/geekbench/k21-result-page.txt`.
- **Android's figures** were reported to us; we didn't run them. Android numbers were also reported for 3DMark Sling Shot Extreme (3,643 to 3,772), GFXBench Car Chase (1,570 frames) and Geekbench 4 (about 4,200 multi-core). Those apps run only on Android, so there's nothing on Linux to compare.

## The system

| Test | Result | Notes |
|---|---|---|
| Boot to the login screen | 20.94 s (10.75 kernel + 10.18 userspace) | 22.4 s on a later boot (`benchmarks/system/k21-boot-later.txt`). Most of the kernel's time is spent waiting for the SSD, which appears about 9 s in. |
| Idle power | 6.7 W | CPU 46 °C, GPU 44 °C, memory 49 °C |
| Power in SuperTuxKart | 12.5 W | at 1920x1080 |
| 7-Zip 26.05 `7z b`, four cores | 9,853 MIPS | 7,015 compressing, 12,690 decompressing |
| Memory, sysbench, 4 threads, 64 MiB blocks | read 9,769 MiB/s (10.2 GB/s), write 19,632 MiB/s (20.6 GB/s) | At 800 MHz: 8,802 and 10,442 MiB/s. Writes gain 88% at 1600 MHz. The bus peaks at 25.6 GB/s. |
| Storage, fio, 1 GiB file, direct I/O | write 25 MiB/s, read 28 MiB/s, 4 KiB random reads 2,670 IOPS | The SSD is on a USB 2 link (480 Mbit/s), see [problems](problems.md) |
| Wi-Fi, TCP with a laptop | 47 Mbit/s to the SHIELD, 22 Mbit/s from it | 5 GHz at −67 dBm; the link reports 270 Mbit/s down and 88 up. The laptop was on Wi-Fi too, so both shared the air. |

Two corrections to the first write-up (NOTES.md B8, commit 0b5f5c0, the results card):
- **Memory units.** The memory figures were sysbench's MiB/s, but they were written as GB/s ("19.6 GB/s"). The write speed is 19,632 MiB/s, which is 20.6 GB/s.
- **Storage units.** `tools/system-benchmark.sh` printed MiB/s labelled as MB/s. The label is fixed now.

**Memory blocks:** sysbench's 1 MiB blocks read 26,562 MiB/s and wrote 31,349 MiB/s. That is above the bus's peak, so those runs measured the CPU's 2 MiB L2 cache, not the memory, and only the 64 MiB rerun counts.

## Graphics

**glmark2 2023.01**, off-screen (`glmark2-es2-wayland --off-screen`), scores 847 at its default 800x600 and 288 at 1920x1080. Some of its scenes in frames per second, with the memory clock at 800 MHz (kernel #16) and then 1600 MHz (kernel #18):

| Size | terrain | texture | build |
|---|---|---|---|
| 1920x1080 | 15 → 24 | 201 → 353 | 217 → 433 |
| 960x540 | 28 → 42 | 707 → 1,200 | 680 → 1,177 |

**SuperTuxKart 1.5**'s built-in benchmark (`supertuxkart --benchmark`, the same replay every time, graphics at low) ran in a 1054x1054 window unless the row says 1920x1080:

| Kernel | EMC | Setting | FPS | What changed |
|---|---|---|---|---|
| #15 | 800 | dynamic lighting | 3.4 | The first run. 69% of the CPU time went to cleaning caches. |
| #16 | 800 | dynamic lighting | 3.2 | Less cache cleaning; the GPU is now the limit |
| #16 | 800 | no dynamic lighting | 17.9 | Dynamic lighting is the slow path: 5.6 times slower |
| #19 | 800 | no dynamic lighting | 17.7 | |
| #19 | 1600 | no dynamic lighting | 20.7 | The memory clock |
| #20 | 1600 | no dynamic lighting | **37.2** | The cache fix, rewritten to track writes |
| #20 | 1600 | 1920x1080, full screen | 30.7 to 30.9 | |
| #21 | 1600 | 1920x1080, full screen | **31.3** | Review fixes, at no cost |

- **Same settings:** from 17.7 to 37.2 FPS is 2.1 times as fast, from two changes: the memory clock and the cache fix.
- **Dynamic lighting:** the runs with it on aren't comparable with the rest.
- **Invalid runs:** two runs on kernel #18 (9.6 and 10.0 FPS) don't count. The screen was locked and the TV off, and Hyprland slows a hidden window down.
- **Raw outputs:** `benchmarks/README.md` lists each run.

## Stability

- **CPU:** 10 minutes on all four cores at 2014 MHz levels off at 61–62 °C, with the fan at level 2 and 12.1–13.0 W (`benchmarks/cpu/`).
- **Memory clock, each step:** memtester over 256 MiB passed right after each step up: 1065.6, 1331.2 and 1600 MHz, 18 checks each.
- **Memory clock, 36-minute soak at 1600 MHz:** memtester over 1 GiB, four loops, with glmark2 running alongside, passed all 72 checks. No memory controller, IOMMU, GPU, lockup or out-of-memory message appeared. CPU 54–64 °C, GPU 52–58 °C, memory 54–59 °C (`benchmarks/memory-clock/`).

## Not measured

- **GPU compute:** no Geekbench GPU score, because it needs Vulkan or OpenCL. NVK, Mesa's Vulkan driver for NVIDIA, doesn't support Tegra (commit ae087db), and no OpenCL driver is set up.
- **Ethernet:** the driver finds the chip, but no link has been tested yet, because there's no switch to plug into.
- **Not measured yet:** video playback, audio, and the SSD on a USB 3 link.

## How to repeat them

| Test | Command |
|---|---|
| Boot, power, 7-Zip, memory, glmark2, storage, Wi-Fi | `tools/system-benchmark.sh <address>` |
| SuperTuxKart | `tools/stk-benchmark.sh <address> [NAME=value] [--option]` (the desktop user must be logged in at the TV, unlocked) |
| The memory clock | `tools/emc-rate.sh <address> 1600000000`. It is back at 800 MHz after each boot. |
| Geekbench | by hand, the Linux AArch64 preview. It uploads its result publicly (NOTES.md B8). |
