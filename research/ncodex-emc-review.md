# EMC table and rate-switching review

## Verdict

The table conversion is substantially consistent with Linux's Tegra210 EMC ABI, and the fixed reserved-memory placement is safe against the memory layout currently documented. Probe at the inherited 800 MHz should not itself perform a clock transition. I would nevertheless **not enable 1600 MHz or a persistent rate service yet**. Two driver hazards materially weaken the proposed rollback and hot-soak plan:

1. Linux's thermal-refresh state is not updated after an MR4 refresh request, and with no derated table the hottest state also falls back to nominal refresh.
2. The r21021 DLL prelock path contains unbounded polling loops while interrupts are disabled, so a sysrq timer is not a reliable recovery mechanism for a failed high-rate transition.

The first boot/probe-only test at 800 MHz is reasonable. Rate switching should wait for the thermal issue to be addressed and should use an independent hardware watchdog or equivalent power recovery.

## Findings, ranked

### High — MR4 thermal refresh handling is unsafe for a hot soak

`tegra210_emc_set_refresh()` selects a requested refresh mode but never stores it in `emc->refresh` (`vendor/linux/drivers/memory/tegra/tegra210-emc-core.c:766-812`). `tegra210_emc_adjust_timing()` later switches on `emc->refresh` (`:1492-1526`), which remains initialized to `TEGRA210_EMC_REFRESH_NOMINAL` at probe (`:1916`). Meanwhile the MR4 poller updates the remembered temperature after calling the setter (`:588-678`). The likely result is that a request for 2x/4x refresh does not actually alter the timing, but subsequent polls may consider the temperature transition handled.

There is a second issue for this particular one-table setup: `TEGRA210_EMC_REFRESH_THROTTLE` chooses the nominal table when there is no derated table (`:785-788`), and `adjust_timing()` treats THROTTLE like NOMINAL (`:1499-1502`). Thus the hottest MR4 states cannot obtain 4x refresh merely by fixing the missing state assignment.

The inherited Tegra210 thermal maps request EMC cooling at 70°C (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:2141-2176`). Do not perform a high-temperature soak or enable a persistent service until this is fixed or a verified derated table exists. A conservative fix needs both:

- update `emc->refresh` only after a successful transition; and
- when no derated table is present, map the hottest state to 4x refresh rather than nominal, unless NVIDIA's downstream behavior establishes another safe fallback.

The refresh registers and debug state should be observed while deliberately crossing the thermal trip before treating thermal protection as functional.

### High — sysrq-b cannot recover every transition hang

The r21021 DLL prelock procedure has unbounded `while (true)` polling loops (`vendor/linux/drivers/memory/tegra/tegra210-emc-core.c:1139-1214`, notably `:1162`, `:1197`, and `:1204`). A rate transition runs under `spin_lock_irqsave()` (`:1528-1568`). If DLL lock never arrives, the CPU can spin with interrupts disabled and the scheduled sysrq timer will never execute.

This is particularly relevant because entries from 1065.6 MHz upward enable periodic training and the high-rate entries use the DLL. Use an independently expiring hardware watchdog, or guaranteed remote/manual power control, for the first transitions. Adding bounded timeouts and a defined failure path would be preferable before persistence. A timer on another CPU is **UNCERTAIN** as a recovery mechanism because reboot/IPI progress can still depend on the wedged CPU and shared state.

### Medium — the imported table needs fail-closed bounds and revision validation

The captured RAM-code-1 table is internally compatible with the kernel's fixed arrays: revision 7, and counts 221 burst, 8 burst-per-channel, 138 trim, 10 trim-per-channel, 33 MC, 24 LA/up-down, 4 vref, 20 training, and 5 DRAM timings. However, Linux later trusts these count fields in array loops, including `num_up_down` in r21021 transition programming (`vendor/linux/drivers/memory/tegra/tegra210-emc-cc-r21021.c:964-972` and `:1407-1413`). The U-Boot converter verifies property byte lengths but does not independently reject count values larger than the destination capacities.

Also, Linux's timing validation skips, rather than rejects, an entry whose revision differs from the first (`tegra210-emc-core.c:1786-1807`), while selecting one revision-specific sequence from the first entry (`:1897-1913`). U-Boot should therefore reject mixed revisions and reject every count above the corresponding `TEGRA210_EMC_MAX_*` capacity—preferably require the exact known counts for this cboot release. This does not invalidate the current captured table; it prevents a different or damaged firmware DT from becoming unchecked kernel array indexing.

### Medium — the first PLLM/PLLMB handoff deserves register-level preflight

The clock driver supports `pllm_ud`/`pllmb_ud` parents and validates the encoded source/divider (`vendor/linux/drivers/clk/tegra/clk-tegra210-emc.c:17-49`, `:303-369`). It has an explicit same-parent retune path that switches between PLLM and PLLMB, programs the alternate PLL, performs the EMC transition, and reparents (`:126-264`). Tegra210 supplies exact PLLM rates for 1065.6, 1331.2, and 1600 MHz and registers both `_ud` fixed-factor clocks (`vendor/linux/drivers/clk/tegra/clk-tegra210.c:1863-1941`, `:3234-3256`). This is positive evidence that the path was designed for these rates.

**UNCERTAIN:** cboot may leave the PMC PLLM override active. The generic PLL code has Tegra PLLM/PLLMB override handling (`vendor/linux/drivers/clk/tegra/clk-pll.c:655-690`), but the PLLMB parameterization and shared override state are not obviously equivalent to cboot's setup. Before the first switch, capture the PMC PLLM override register and CAR PLLM/PLLMB/EMC source registers and compare them with what the mainline clock driver believes. This is a preflight check, not evidence that the path is broken.

### Low — the reserved size does not actually hold 16 entries plus a terminator

One timing is 4,928 bytes. A `0x14000` region holds 16 complete records with 3,072 bytes left, but the converter reserves one zero record as a terminator, so its effective maximum is 15. The current table has ten entries and is safe. Either correct the comment/expectation, permit all 16 because Linux already stops at its 16-entry maximum, or make the carveout at least 17 records (`0x14740`; rounding to `0x15000` is simpler).

### Low — string checks do not enforce the stated exact representation

The scalar/array properties require exact lengths, but the two string properties are copied with truncation semantics. The known `dvfs-version` and source strings fit, so this is not a current defect. For fail-closed behavior, reject strings without an in-property NUL or whose length exceeds the destination. Offset assertions for major struct members would also make the ABI mirror more robust than a size assertion alone.

## 1. Converter and ABI mapping

The converter's native structure matches `struct tegra210_emc_timing` in `vendor/linux/drivers/memory/tegra/tegra210-emc.h:802-872`; the 1,232-word static size check is correct. The generated reference tool reports 61 fields, 1,232 words, ten RAM-code-1 rates, and all ten trained. Native-endian writes are correct: this region contains C structures, not flattened-DT cells. Using `fdt32_to_cpu()` for FDT numeric properties and then storing native `u32` values is therefore appropriate. The `/chosen` copy is likewise an opaque native-endian byte copy.

The questioned mappings agree with kernel consumption:

- `src-sel-reg` → `clk_src_emc` is used as the programmed EMC clock-source word (`tegra210-emc-core.c:1932-1947`).
- `dll-clk-src` and `clk-out-enb-x-0-clk-enb-emc-dll` feed the DLL/source setup (`:733-763`).
- `emc-clock-latency-change` → `latency` is semantically and structurally correct, although the current mainline transition path appears not to consume `latency`.
- `run_clocks` is used for the training/MR23 sequence and oscillator count; `tree_margin` is used by periodic compensation (`tegra210-emc-cc-r21021.c:116-146`, `:818-821`).
- The current/trained DRAM clktree values are consumed by compensation and should be copied as done.
- `la-scale-regs-num` → `num_up_down` is correct. The r21021 sequence writes the LA values before a downclock and after an upclock (`:964-972`, `:1407-1413`). The captured value 24 equals the array capacity.

Rates are kHz in the timing structure; the core converts them to Hz for the clock framework (`tegra210-emc-core.c:1880-1895`, `:1932-1947`). `min_volt` is in mV and is currently used for validation, not regulator scaling. The fixed 1125 mV core rail is above the table's maximum 887 mV. `gk20a-min-mv`/`gpu_min_volt`, `needs_training`, `training_pattern`, `latency`, `dvfs_ver`, and `clock_src` are present in the ABI but some are not directly acted on by this mainline sequence. The constant 1100 mV GPU value therefore does not appear to be an enforced GPU-voltage prerequisite here; its original downstream purpose is **UNCERTAIN**.

`tools/emc-table.py` is a good byte/layout/endian cross-check because it derives the C layout from the kernel header. It is not completely independent semantically—the property mapping is duplicated from the converter—but it should catch ordering, size, copy, and endian mistakes. Compare against the `/chosen` bytes from the same boot, not merely the checked-in cboot dump.

## 2. Probe behavior, training, and thermal handling

`CONFIG_TEGRA210_EMC=m` is viable for the reserved-memory handoff. `TEGRA210_EMC` selects the boolean `TEGRA210_EMC_TABLE`; the table handler is built separately, so its `RESERVEDMEM_OF_DECLARE` initialization is available during early reserved-memory scanning (`drivers/memory/tegra/Kconfig:66-73`, `drivers/memory/tegra/Makefile:23-30`). It is not deferred until the EMC module loads.

At probe, the driver maps/registers resources, acquires the nominal table, finds the entry exactly matching the current 800 MHz clock, installs per-rate clock configurations, constrains the allowed range, initializes debugfs, and registers cooling (`tegra210-emc-core.c:1810-1977`). Since 800 MHz is within the table range, `clk_set_rate_range()` should not force a transition. Verify that empirically by reading both the EMC clock and debug state before and after module load.

Periodic compensation is not started merely by probe. Its 100 ms timer starts after a transition into a timing whose `periodic_training` flag is set (`tegra210-emc-core.c:558-586`, `:720-728`; `tegra210-emc-cc-r21021.c:243-329`). The 800 MHz entry has it clear; 1065.6 MHz is therefore the first rate that exercises both a clock transition and periodic training.

MR4 polling likewise is not continuously started at ordinary probe; the cooling state starts/stops it (`tegra210-emc-core.c:588-718`). This makes an initial cool 800 MHz module-load test low risk, but it does not resolve the thermal defect above.

## 3. Switching and memory-controller programming

The high-rate `clk_src_emc = 0x80188000` selects a supported PLLM-derived parent with an acceptable divider. The clock code does not merely assume cboot's PLL stays untouched; it can configure the alternate PLLM/PLLMB and hand the EMC across. The main uncertainty is inherited override/register state, so the safest initial experiment records the relevant registers before and after the 800→1065.6 transition.

The r21021 transition sequence programs the copied MC register block and the latency-allowance scale array (`tegra210-emc-cc-r21021.c:951-972`, `:1407-1413`). Thus scanout clients are not intentionally left with the 800 MHz LA values. A brief display glitch may still occur during a transition. Persistent DC underflow, HDMI loss, MC/SMMU errors, or nouveau faults are failure signals, not cosmetic effects to ignore.

**UNCERTAIN:** `tegra210_emc_reset_dram_clktree_values()` appears not to reset both C0D1 clktree fields (`tegra210-emc-core.c:1443-1457`). The captured C0D1 values are zero, which likely reflects a single-rank/device topology, so this may be irrelevant on darcy, but it is worth confirming against downstream code before relying on repeated thermal/training cycles.

## 4. Reserved-memory placement

`0xb0200000..0xb0213fff` lies wholly inside cboot's second reported DRAM bank (`0xa0000000..0xfedfffff`) and immediately after, without overlapping, ramoops (`0xb0000000..0xb01fffff`). It is far from the documented kernel load at `0x80200000`, cboot/FIT/FDT locations around `0x83100000`/`0x84100000`, and U-Boot relocation near the top of low DRAM. The current fixed placement is therefore safe against the known layout.

`in_dram()` proves only membership in a DRAM bank, not absence of overlap with every reserved region. Keeping the explicit DTS placement and validating it against each boot's memory/reserved-memory map is important.

Cboot's VPR node describes a dynamic reusable allocation range; an `alloc-ranges` property alone is not a live 400 MiB allocation, and it is not copied into the FIT's kernel DT. There is therefore no visible DT reservation colliding with `0xb0200000`. **UNCERTAIN:** a secure monitor or cboot could leave a hardware VPR aperture active without accurately reflecting it in the passed memory map. Reading the MC VPR registers before using the region would remove that uncertainty.

`no-map` plus `memremap(..., MEMREMAP_WB)` is valid on arm64. The no-map reservation keeps it out of the linear mapping, after which arm64's `arch_memremap_wb()` can create a cacheable mapping (`vendor/linux/kernel/iomem.c:69-116`; `vendor/linux/arch/arm64/mm/ioremap.c:17-58`). The table handler maps, counts, and attaches the region as expected (`drivers/memory/tegra/tegra210-emc-table.c:12-56`).

## 5. Revised test plan

1. **Boot and probe only at 800 MHz.** Confirm U-Boot selected RAM code 1 and printed exactly the ten expected rates. Extract the cboot DT and `/chosen/darcy,emc-table` from that same boot, run the byte comparison, confirm `TEGRA210_EMC_TABLE=y` and `TEGRA210_EMC=m`, then load the module. Require the rate to remain exactly 800 MHz and all ten rates to appear.
2. **Resolve thermal refresh before hot testing or persistence.** Until then, keep the board demonstrably below the EMC thermal threshold; that is a diagnostic constraint, not a production solution.
3. **Use independent recovery.** Arm a hardware watchdog that Linux cannot continuously pet while wedged, and retain manual/remote power control. The sysrq timer is useful only as an additional mechanism.
4. **Record clock/PMC state.** Capture PLLM/PLLMB, PMC override, and `CLK_SOURCE_EMC` before loading the module and around the first switch. Confirm the actual resulting EMC clock; a successful debugfs write alone is insufficient.
5. **Exercise 800↔1065.6 repeatedly before proceeding.** 1065.6 is the correct first upward step because it is the next table entry, but it also activates periodic compensation. Let it idle for several minutes, inspect training/debug data and logs, then test multiple up/down cycles. Merely lowering `min_rate` may not downclock immediately; restore the low minimum and set an appropriate maximum when intentionally testing a downshift.
6. **At every rate, combine loads.** First use a moderate memory smoke test, then concurrent memory, GPU rendering, and HDMI scanout. A 512 MiB single pass is not adequate qualification. Use roughly 60–80% of currently free RAM without inducing OOM, run multiple passes for 30–60 minutes at each intermediate rate, and reserve a multi-hour/overnight run for 1600 MHz after the lower rates are stable.
7. **Protect persistent data.** Early stress should run from initramfs or a read-only root where practical, with nonessential writable filesystems unmounted. Marginal DRAM can corrupt filesystem metadata before producing a clean crash. Hash known test data before and after.
8. **Watch broad failure signals.** Tegra210 has no ECC to make marginal timing obvious. Monitor for silent hash mismatches, SIGSEGV/SIGILL, page faults, filesystem checksum/I/O errors, watchdog resets/pstore, nouveau hangs, SMMU/MC errors, DRM/DC underflow, HDMI blanking, and changes in periodic-training values.
9. **Qualify temperature and cold boot separately.** After the refresh fix, repeat under cold-start and thermally warm conditions and explicitly verify MR4-driven refresh changes. Test several cold boots and long soak cycles before creating a service.
10. **Persist last.** Only enable a boot-time 1600 MHz service after the table has been reproduced across boots, PLL handoff is understood, repeated bidirectional transitions pass, thermal refresh is verified, and long combined memory/GPU/display tests remain clean.

Overall, the imported cboot table is plausible and well matched to the mainline ABI; the larger risks are in the Linux transition/thermal machinery and recovery assumptions, not the basic field copy.
