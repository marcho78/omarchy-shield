# Benchmark outputs

These are the raw outputs behind the numbers in `docs/benchmarks.md`, as the tools printed them, with three changes:
- Colour codes are removed.
- The Geekbench claim link is removed, because it lets anyone add the result to their own profile.
- Lines starting with `#` were added here, to say what a file holds.

All of it ran on a SHIELD TV 2017 with Linux 7.2.11 and our patches, the root filesystem on a USB SSD, on 2026-10-23. A file name starts with the kernel build (`k21` is kernel #21; `docs/timeline.md` lists them). It gives the memory clock, EMC, where that matters: 800 MHz is where cboot leaves it, and 1600 MHz is stock's top rate.

## SuperTuxKart 1.5 `--benchmark`

`tools/stk-benchmark.sh` replays the same race each time. Graphics are at low, in a 1054x1054 window unless the row says 1920x1080. All files are in `supertuxkart/`.

| File | Kernel, EMC | Settings | FPS |
|---|---|---|---|
| `k15-dynamic-lighting.txt` | #15, 800 | Dynamic lighting on. The game's own log lines, from an earlier script. | 3.4 |
| (no file) | #16, 800 | Dynamic lighting on. The tool stopped before printing, so this was read by hand (NOTES.md B6). | 3.2 |
| `k16-dynamic-lighting-rgba8.txt` | #16, 800 | Dynamic lighting on, float render targets off | 3.4 |
| `k16-no-dynamic-lighting.txt` | #16, 800 | | 17.9 |
| `k18-emc800-invalid.txt`, `k18-emc1600-invalid.txt` | #18, 800 and 1600 | **Invalid.** The session was locked and the TV off, so Hyprland slowed the game down. | 9.6, 10.0 |
| `k19-emc800.txt` | #19, 800 | | 17.7 |
| `k19-emc1600.txt` | #19, 1600 | | 20.7 |
| `k19-emc1600-with-perf.txt` | #19, 1600 | With `perf` recording (NOTES.md B7) | 20.5 |
| `k20-emc1600-window.txt` | #20, 1600 | | 37.2 |
| `k20-emc1600-1080p.txt` | #20, 1600 | 1920x1080 full screen. The game kept full screen from the run before. | 30.9 |
| `k20-emc1600-1080p-hud.txt` | #20, 1600 | 1920x1080 full screen, with Mesa's frame-rate overlay | 30.7 |
| `k21-emc1600-1080p-hud.txt` | #21, 1600 | 1920x1080 full screen, with the overlay | 31.3 |

## glmark2 2023.01, off-screen

All files are in `glmark2/`. The overall scores, 847 at 800x600 and 288 at 1920x1080, are in `system/k21-system-benchmark.txt`.

| File | Kernel, EMC | What |
|---|---|---|
| `k16-emc800-sizes.txt` | #16, 800 | The terrain, texture and build scenes at four sizes |
| `k18-emc1600-sizes.txt` | #18, 1600 | The same scenes at two sizes |

## The whole system (kernel #21, EMC 1600)

| File | What |
|---|---|
| `system/k21-system-benchmark.txt` | `tools/system-benchmark.sh`, first run: boot time, idle power, 7-Zip, glmark2, storage, Wi-Fi. Its memory lines used 1 MiB blocks, which measured the CPU's 2 MiB L2 cache, not the memory: use the rerun. Its storage lines say MB/s, but they are MiB/s. |
| `system/k21-boot-later.txt` | systemd-analyze on a later boot of the same kernel: 22.4 s |
| `system/k21-reruns.txt` | Memory with 64 MiB blocks at 1600 and at 800 MHz, the SSD's USB link (480 Mbit/s) and the Wi-Fi link |
| `geekbench/k21-cli.txt` | What Geekbench 6.7.1 (the Linux AArch64 preview) printed. It shows no scores and uploads every result. |
| `geekbench/k21-result-page.txt` | The text of the result page, browser.geekbench.com/v6/cpu/19382032: 317 single-core, 854 multi-core, and each subtest |

## The memory clock (kernel #18)

| File | What |
|---|---|
| `memory-clock/k18-memtester-1066mhz.txt`, `-1331mhz.txt`, `-1600mhz.txt` | memtester over 256 MiB, one loop, after switching to each rate. All 18 checks pass at each rate, so the three files read the same. |
| `memory-clock/k18-soak-1600mhz.txt` | The 36-minute soak at 1600 MHz: the rate, the DRAM's temperature state and the temperatures, each minute |
| `memory-clock/k18-soak-memtester.txt`, `k18-soak-glmark2.txt` | What ran during the soak: memtester over 1 GiB for four loops, and glmark2 alongside it |

## CPU

| File | What |
|---|---|
| `cpu/soak-2014mhz.txt` | Ten minutes on all four cores at 2014 MHz: clock, fan, temperatures and board power every 30 s. It ran before the kernel builds were numbered; commit 4a93eab has it. |

## Not kept

- **Debug logs:** the logs behind NOTES.md's bring-up sections (display handoff, GPU) stayed in a temporary folder and are gone. NOTES.md quotes what they showed.
- **Android:** its numbers in `docs/benchmarks.md` are as reported to us, not runs of ours.
