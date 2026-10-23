# Review brief: the SHIELD's memory clock (EMC) from 800 to 1600 MHz on mainline

Repo: `~/projects/nvidia`. The kernel is Linux 7.2.11 (`vendor/linux` with `patches/linux`), U-Boot is `vendor/lineage-u-boot` with `patches/u-boot`, and the hardware is a SHIELD TV 2017 (darcy, Tegra210, LPDDR4, 3 GiB). NOTES.md B7 has the background. Kernel #17, U-Boot and the boot image are building now. **Nothing has run yet; nothing will be flashed before your review.**

## Facts, checked

- The EMC is at 800 MHz, the rate cboot left. The kernel had no EMC driver (`# CONFIG_TEGRA210_EMC is not set`).
- `patches/u-boot/0002` (flashed, works) puts cboot's own device tree in `/chosen/darcy,cboot-fdt`, 564,579 bytes. A copy is at `device-info/cboot-fdt/cboot.dtb` / `.dts`.
- cboot's `external-memory-controller@7001b000` has `emc-table@0` (`nvidia,ram-code = <0>`, dvfs-version "03_…", `nvidia,trained = <0>` everywhere) and `emc-table@1` (`ram-code = <1>`, "02_…", `nvidia,trained = <1>` at all ten rates: 40.8, 68, 102, 204, 408, 665.6, 800, 1065.6, 1331.2 and 1600 MHz). There are no derated tables. The 1600 MHz entry: `nvidia,source = "pllm_ud"`, `src-sel-reg = 0x80188000`, `needs-training = 0x2f0`, `periodic_training = 1`, trained clktree c0d0u0 0x14b / c0d0u1 0x157 / c1d0u0 0x14f / c1d0u1 0x157.
- The straps: `APB_MISC_PP_STRAPPING_OPT_A` = 0x00001c10, RAM code (bits 7:4) = 1.
- Voltages: `emc-min-mv` runs from 800 (≤204 MHz) to 887 (1600 MHz). vdd-core is fixed at 1125 mV (regulator summary, min 600, max 1400). `gk20a-min-mv` is 1100 at **every** rate, 800 MHz included, and we run at 800 MHz today with vdd-gpu at 838 mV without trouble.
- Mainline `tegra210-emc` takes its table from reserved memory (`RESERVEDMEM_OF_DECLARE` "nvidia,tegra210-emc-table"; `memory-region-names` "nominal"/"derated"). It counts entries up to 16 until a zero revision, validates rising rates and min_volt, needs an entry equal to the current clock rate, needs `trained` above 204 MHz (`tegra210-emc-core.c:1551`), supports revision 7 (r21021), and changes the rate only through debugfs `emc/min_rate` / `max_rate` (clk_set_min/max_rate).

## The change (please review the code)

1. **`patches/u-boot/0003-board-nvidia-p2894-give-linux-cboot-s-trained-emc-table.patch`**: `emc_table_from_cboot()` runs in `ft_board_setup()`.
   - It finds the kernel DT's `nvidia,tegra210-emc-table` region, checks it lies in DRAM (`in_dram`) and is at least two entries long, and zeroes it.
   - It reads the RAM code from the straps, picks cboot's table with the matching `nvidia,ram-code`, and fills one `struct emc_timing` per rate. The struct mirrors Linux's `struct tegra210_emc_timing`, with `_Static_assert(sizeof == 1232*4)`.
   - Each field comes from a property table (`emc_props[]`), and every property must exist at its exact length. The strings are `nvidia,dvfs-version` → `dvfs_ver[60]` and `nvidia,source` → `clock_src[32]`.
   - Rates above 204 MHz must be trained. The entries are insertion-sorted by rate and bounded by the region and 16.
   - Any failure zeroes the region again.
   - On success it prints a summary and copies the table to `/chosen/darcy,emc-table`.
2. **`kernel/dts/darcy.dts`**: `emc_table: emc-table@b0200000 { compatible = "nvidia,tegra210-emc-table"; reg = <0x0 0xb0200000 0x0 0x14000>; no-map; }`, right after our ramoops carveout at 0xb0000000 (2 MiB), plus `&emc { memory-region = <&emc_table>; memory-region-names = "nominal"; };`. cboot's /memory: 0x80000000+0x1f200000, 0xa0000000+0x5ee00000, 0x100000000+0x40000000. Its reserved-memory: iram at 0x40001000, ramoops at 0xb0000000/2 MiB, VPR as a dynamic 400 MiB alloc-ranges 0x80000000+0x70000000, and fb0/fb1 at zero size.
3. **`kernel/darcy.config`**: `CONFIG_TEGRA210_EMC=m`.
4. **`tools/emc-table.py`**: an independent reference. It parses the struct layout from `tegra210-emc.h` (61 fields, 1232 words) and the DTB with its own FDT parser, then builds the expected table and compares it field by field with `/chosen/darcy,emc-table`.
5. **`patches/linux/0006`** is also updated with your earlier points: CPU_FINI reserves, `nouveau_sgdma_populated()` marks `sync_pending` from `nouveau_ttm_tt_populate()` (not for AGP TTs), and `.access` marks only writes.

## The test plan

1. Flash, boot, log in. Check dmesg for tegra210-emc probe errors, debugfs `emc/available_rates` (the ten rates), and that the clock is still 800 MHz. Run `tools/emc-table.py device-info/cboot-fdt/<this boot's cboot.dtb> --compare <chosen/darcy,emc-table>`.
2. Arm a sysrq-b rollback timer (3 min). `echo 1065600000 > emc/min_rate`, then memtester over 512 MiB (one loop), glmark2 terrain, and check dmesg. Cancel the timer. Repeat at 1331.2, then 1600.
3. At 1600: STK benchmark (`tools/stk-benchmark.sh`), glmark2 off-screen, and a longer memtester or stress run. Then persist with a boot-time service that sets the rate.

## Questions

1. Is the converter right? In particular `src-sel-reg` → `clk_src_emc`, `dll-clk-src`, `clk-out-enb-x-0-clk-enb-emc-dll`, `emc-clock-latency-change` → `latency`, `needs-training`, `run_clocks`/`tree_margin`, the `current_dram_clktree` set, and `num_up_down` ← `la-scale-regs-num`. Does anything in r21021, `clk-tegra210-emc.c` or the core read fields that downstream filled differently from the DT (units: kHz for rate, mV for min_volt)?
2. Probe: does `tegra210-emc` touch the hardware at probe, while the EMC stays at 800 MHz? Periodic training (`periodic_training = 1`), the MR4 temperature polling and refresh changes, and the cooling device are all candidates. Is that safe with only a nominal table, and how does it handle hot DRAM without a derated table?
3. Switching: is the clock path for `pllm_ud` (1600) versus the lower rates' sources supported in mainline's `clk-tegra210-emc.c` with `clk_src_emc` as cboot wrote it? Does mainline's PLLM programming match what cboot set up?
4. Is the 0xb0200000 region safe? It must not collide with U-Boot (relocation, bootm loads, the FDT it relocates) or with cboot's VPR alloc-range (the kernel DT has no VPR). Does `no-map` plus `memremap(MEMREMAP_WB)` in `tegra210_emc_table_device_init` work on arm64?
5. Safety: what else should the test plan include or change? Memory test choice and size, how long to soak, signs of marginal timing, and whether to step 800 → 1065.6 → 1331.2 → 1600 or start lower. Also the EMC rate's effect on the display (scanout underflow, la_scale), and whether mainline's MC programs latency allowance per rate (`la_scale_regs`).

Analysis only: change nothing in the repo or on the SHIELD.
