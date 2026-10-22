# Linux handoff review

## Verdict

The kernel/FIT placement and the framebuffer `no-map` reservation look sound. The two boot-argument changes are useful, but `regulator_ignore_unused` is **not sufficient** to preserve the firmware HDMI path: several GPIO-controlled fixed regulators can be driven low during their initial probe before the regulator core applies `always-on`. I would fix that before the first blind boot.

The next most concerning item is Tegra SMMU initialization. Its ability to disturb cboot's live display is **UNCERTAIN**, but it performs global SMMU reprogramming and TLB/PTC flushes while no Linux consumer needs the SMMU in this payload. Disabling it for the canary kernel is the safest choice.

## Ranked findings

### 1. High: fixed-regulator probe can pulse live display rails low

This is the strongest concrete explanation for losing the inherited framebuffer even if Linux continues running.

In `drivers/regulator/fixed.c:191-192`, `enabled_at_boot` is derived from `constraints.boot_on`, not `always_on`. The GPIO is then requested as output-low unless `enabled_at_boot` is true (`drivers/regulator/fixed.c:295-298`), before regulator registration (`drivers/regulator/fixed.c:317-327`). Only later does the regulator core enforce boot/always-on constraints. `drivers/regulator/of_regulator.c:131-132` parses those two properties independently.

The P2894 DTS has GPIO-controlled rails that are `regulator-always-on` but lack `regulator-boot-on`, notably:

- `vdd_sys_boost`, the upstream supply for HDMI 5 V (`arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi:1707-1730`)
- `vdd_3v3` (`tegra210-p2894.dtsi:1648-1658`)
- `vdd_disp_3v0` (`tegra210-p2894.dtsi:1777-1787`)

Thus fixed-regulator probe can briefly deassert the GPIO. A pulse on `vdd_sys_boost` can drop HDMI 5 V/HPD; because Linux is not running native Tegra DRM, nothing will retrain the SOR afterward.

Recommended DTS overrides for the first payload:

```dts
&vdd_sys_boost { regulator-boot-on; };
&vdd_3v3       { regulator-boot-on; };
&vdd_disp_3v0  { regulator-boot-on; };
&vdd_hdmi {
        regulator-boot-on;
        regulator-always-on;
};
```

`regulator_ignore_unused` prevents the regulator core's late unused-regulator cleanup (`drivers/regulator/core.c:6850-6875`); it does not prevent this earlier GPIO transition. Therefore the boot-argument change is correct, but not enough.

### 2. High impact, likelihood UNCERTAIN: SMMU probe may disturb firmware scanout

`CONFIG_TEGRA_IOMMU_SMMU=y` causes the memory-controller driver to probe the Tegra SMMU (`drivers/memory/tegra/mc.c:1004-1009`). SMMU initialization rewrites global PTC/TLB configuration, flushes both, and enables the SMMU (`drivers/iommu/tegra-smmu.c:1147-1165`).

It is **UNCERTAIN** whether cboot left the display controller using SMMU translation on this unit, and whether any firmware page tables it relies on remain adequately reserved and compatible with the Linux initialization. The driver does not obviously overwrite a display-client ASID at probe, but its global flush/reconfiguration is unnecessary risk while DC/SOR remain firmware-owned.

For the first canary, set `CONFIG_TEGRA_IOMMU_SMMU=n`. `iommu.passthrough=1` is not equivalent: it does not prevent probe-time register writes and flushes. Re-enable the SMMU when native host1x/DRM work begins.

### 3. Medium: U-Boot creates the simple-framebuffer node in the wrong location

The patch calls `fdt_add_subnode(blob, 0, "framebuffer")` in `patches/u-boot/0001-board-nvidia-add-SHIELD-TV-2017-P2894-darcy.patch:642-672`. The simple-framebuffer binding requires a `/chosen/framebuffer@<address>` child (`Documentation/devicetree/bindings/display/simple-framebuffer.yaml:18-20`).

The current root-level node will **probably** still probe because normal root platform population follows the special `/chosen` framebuffer scan (`drivers/of/platform.c:581-604`), but relying on generic population is avoidable and the node name also violates the unit-address convention despite containing `reg`.

Create or find `/chosen`, then add `framebuffer@92cc3000` beneath it (derive the unit address dynamically rather than hard-coding it). Keeping the corresponding `/reserved-memory` child separate is correct. A `stdout-path` can be supplied, although `console=tty0` plus fbcon should already select the display console once simpledrm registers.

### 4. Medium impact, likelihood UNCERTAIN: clock initialization still touches display-related PLL state

`clk_ignore_unused` prevents late clock gating, but it does not make Tegra clock-controller initialization read-only. Tegra210 clock setup clears a PLLD control bit (`drivers/clk/tegra/clk-tegra210.c:3736-3821`), and PLL default setup can update lock-detect/configuration fields even for an already-running PLL (`drivers/clk/tegra/clk-pll.c:1921-1927`; `clk-tegra210.c:936-1039`). The init table also sets PLL_DP to 270 MHz (`clk-tegra210.c:3551-3606`).

The active HDMI SOR1 path appears to use PLL_D2 rather than PLL_DP (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:336-345`), so I rank this below regulators and SMMU. Whether these writes perturb cboot's exact live HDMI configuration is **UNCERTAIN**. There is no clean command-line switch that makes the mandatory Tegra clock provider inert; if the first payload still blanks after the higher-ranked fixes, instrument or temporarily quirk the relevant clock initialization rather than assuming `clk_ignore_unused` covers it.

### 5. Low: enabled devices add unnecessary state changes

The P2894 DTS enables SDMMC4/eMMC (`tegra210-p2894.dtsi:1585-1588`). Linux should only reset, clock, and enumerate it; the initramfs does not mount or write it. Nevertheless, disabling the SDMMC4 node for the first canary reduces both risk and diagnostic noise. Re-enable it after basic handoff is proven.

PMIC, pinctrl, GPIO, PMC, and clocks are less optional. PCIe, XUSB, SOR1, DPAUX, and XUDC remain disabled in the mainline DT, and host1x/DRM_TEGRA are unshipped modules, so native Linux display and USB drivers should not seize those blocks.

The Tegra thermal driver is also an unshipped module, leaving no Linux thermal/fan management. This should not block a short idle test, but do not stress the SoC or leave the canary running unattended.

### 6. Low: CPU idle is probably valid, but can be removed from the first experiment

The DTS uses PSCI 1.0 and the same CPU suspend parameter as the stock Android DT, so there is positive device-specific evidence that the secure monitor implements it. The CPU-frequency driver should defer because the DFLL node is disabled rather than switching clocks. For maximum isolation, adding `cpuidle.off=1` to the first payload is still reasonable; remove it once boot is confirmed.

## Verification of the existing changes and image layout

- The framebuffer reservation change is correct. `fdtdec_add_reserved_memory(..., FDTDEC_RESERVED_MEMORY_NO_MAP)` creates a page-aligned reserved-memory entry with `no-map` (`U-Boot lib/fdtdec.c:1417-1454`). This matters because arm64 `ioremap` rejects ordinary linear-mapped RAM (`arch/arm64/mm/ioremap.c:26-29`), whereas simpledrm maps the framebuffer resource write-combined (`drivers/gpu/drm/tiny/simpledrm.c:756-783`). The framebuffer lies inside bank 0, so an explicit reservation is required.
- `consoleblank=0` is correct but only disables fbcon's idle blanking; it cannot preserve power, clocks, HPD, or link training.
- Add `no-map;` to the custom `ramoops@b0000000` node as well. Reserved-memory already keeps it out of the page allocator, so omission is unlikely to prevent boot, but stock uses `no-map` for this same region and it avoids an unnecessary linear alias.
- No FIT overlap is apparent. The decompressed kernel at `0x80200000` occupies about `0x1980000` bytes and ends near `0x81b80000`; the FIT starts at `0x84100000`. Both are within the first RAM bank. Three cboot memory banks fit U-Boot's `NR_DRAM_BANKS=8`, and U-Boot's 256 MiB bootmap window covers the relevant objects. Clearing `fdt_high` allows an outgoing-DTB relocation below that window; `initrd_high=~0` keeps and reserves the initramfs in place. The arm64 Image header and alignment are consistent with this load address.
- Marking the FIT ramdisk payload `compression = "none"` while its contents are `cpio.gz` is correct: U-Boot must pass the compressed archive unchanged and the kernel's initramfs code decompresses it.

## Recommended first-boot delta

Before the first Linux attempt, I would make only these safety-oriented changes:

1. Add `regulator-boot-on` to `vdd_sys_boost`, `vdd_3v3`, and `vdd_disp_3v0`; make `vdd_hdmi` explicitly boot-on and always-on.
2. Put the simple-framebuffer node under `/chosen` with a unit-address name.
3. Disable `CONFIG_TEGRA_IOMMU_SMMU` for the canary.
4. Add `no-map` to ramoops.
5. Optionally disable SDMMC4 and add `cpuidle.off=1` until the banner is observed.

## No-solder debugging

Ramoops is the best first channel. Add `panic=10 oops=panic` so a kernel failure can warm-reset instead of leaving a static logo. A hard hang will still require watchdog support, which is not presently enabled. Avoid power removal before retrieval because persistent RAM is not persistent across loss of power.

Reading the standard persistent-RAM header/data directly from U-Boot after a warm reset would be more deterministic than assuming Android's downstream ramoops layout and DropBox importer match mainline. Booting Android and checking `/sys/fs/pstore` or `SYSTEM_LAST_KMSG` may work, but compatibility with NVIDIA's downstream ramoops format is **UNCERTAIN**.

USB gadget serial is not a near-term fallback: XUDC and padctl are disabled in the DT, XUDC is an absent module, and device-mode setup also needs PHY/power-domain/role wiring plus gadget function configuration. Treat it as a later bring-up project, not as the first handoff diagnostic.
