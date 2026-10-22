# HDMI-link handoff review

## Bottom line

The leading cause is no longer speculative: the Tegra PMC driver deliberately tears down every DT-described powergate that was on at probe, including `pd_sor`. This happens during PMC probe, independently of `pd_ignore_unused`. It is a substantially stronger explanation than the clock, MC/SMMU, pinctrl, or XUSB hypotheses.

The important correction to the proposed hypothesis is that a bad SMC "off" reading is not required. `tegra_powergate_add()` does this in either state:

- If PMC reports the domain off, it asserts all listed resets.
- If PMC reports it on—as an operating HDMI link strongly implies—it calls `tegra_powergate_power_down()`, which asserts the resets, disables the clocks, and switches the partition off.

See `vendor/linux/drivers/soc/tegra/pmc.c:1347-1379` and the actual power-down sequence at `pmc.c:895-923`. The `sor` node lists SOR0/SOR1/DPAUX/DPAUX1/MIPI_CAL/DSI resets and their clocks at `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:941-959`. `pd_ignore_unused` only suppresses the later unused-domain sweep (`vendor/linux/drivers/pmdomain/core.c:1356-1381`); it cannot suppress this provider-probe teardown.

## 1. Ranked hypotheses and predicted dump

### 1. PMC `pd_sor` registration — very high confidence

`tegra_powergate_init()` iterates every child of `powergates` (`pmc.c:1501-1530`) and `tegra_powergate_add()` normalizes an initially-on domain by powering it down before registering genpd as off (`pmc.c:1361-1398`). This likely runs around the 0.156 s PMC messages. The perceived 1.5–2 s loss can be the TV's loss-of-sync debounce or imprecise visual correlation with fbcon; the exact sink delay is **UNCERTAIN**.

Expected signature:

- U-Boot: SOR1/DPAUX1 clock enabled, reset clear; link active.
- Linux: `powergates off` contains `sor`; genpd says `sor off-0`; SOR1/DPAUX1/MIPI_CAL clocks are off and resets asserted.
- DISP1 can remain enabled/out of reset and DC A's programmed state can remain unchanged. That combination—DC still scanning but the SOR partition dead—is particularly diagnostic.
- If the power-down failed, the log should contain `failed to turn off PM domain sor`; the current `fail` highlighter would retain it.

### 2. Tegra clock initialization — possible, but much less likely

The clock provider is registered very early with `CLK_OF_DECLARE` (`drivers/clk/tegra/clk-tegra210.c:3736-3821`). The init table reparents/enables HOST1X and sets PLL_DP to 270 MHz (`clk-tegra210.c:3551-3606`), but it does not retune PLL_D2, SOR1's pixel-clock parent (`tegra210.dtsi:336-345`). When PLL_D2 is already enabled, `plldss_defaults()` mostly checks the boot MISC values and writes the lock-detect control (`clk-tegra210.c:936-1000`), rather than replacing its rate.

Expected signature: `sor` stays powered, SOR1 reset remains clear, but PLL_D2/SOR1 source or framework rates differ. Note that the current BASE-only comparison can miss a PLL MISC-register write.

### 3. Tegra pinctrl's parked-bit clearing — real write, low probability

Probe unconditionally clears each T210 pingroup's parked bit (`drivers/pinctrl/tegra/pinctrl-tegra.c:731-753,923-930`), including HDMI CEC and HPD groups at mux offsets 0x3198/0x319c (`pinctrl-tegra210.c:1453-1454`). The board's state is named `"boot"`, while pinctrl hogging looks only for `"default"` and `"sleep"` (`drivers/pinctrl/core.c:2210-2244`), so the full board state is not applied.

This affects CEC/HPD pins rather than the TMDS serializer, and no native display driver is present to react to an HPD transition, so it ranks below clocks. Expected signature: all current CAR/PMC/DC readings match U-Boot; only pinmux bit 5 changes. Whether hardware autonomously reacts to HPD here is **UNCERTAIN**.

### 4. MC/SMMU/latency allowance — low

MC probe rewrites all clients' latency-allowance defaults and latches them (`drivers/memory/tegra/mc.c:414-442,530-548`). A bad DC allowance could cause scanout underflow, but underflow normally corrupts/blank-fills pixels rather than shutting off TMDS. SMMU enables translation only when a client is attached; simplefb scans the inherited physical buffer. Expected signature: SOR remains powered and clocked, with DC interrupt/underflow status set—neither status is currently captured.

### 5. XUSB/padctl or simpledrm — very low

XUSB host and padctl remain disabled in the base SoC DT (`tegra210.dtsi:1079-1124`), so their drivers should not probe. simpledrm maps and writes the framebuffer but has no Tegra register programming path; it cannot itself disable TMDS.

## 2. Review of commit `aa661a8`

The register inventory is correct:

- CAR is 0x60006000 (`tegra210.dtsi:493-495`). The L/H/U/V/W/X/Y enable and reset offsets match `drivers/clk/tegra/clk.h:13-19,36-42`.
- All selected IDs match `include/dt-bindings/clock/tegra210-car.h:46-48,69-77,207-209,234,249`. The header warns that clock IDs do not universally equal reset bits (`tegra210-car.h:5-11`), but these particular reset numbers are explicitly used by the T210 `pd_sor` DT node, so the raw reset-bit interpretation is valid here.
- PLLD/PLLD2/PLLDP and SOR1-source offsets match `drivers/clk/tegra/clk-tegra210.c:35,71-97`; DISP1 source is 0x138 in `clk-tegra-periph.c:76-79`.
- DC values are word offsets, and the `uint32_t *` indexing in `tools/darcy-init.c:195-201` correctly multiplies them by four. The highest current access, 0x42e × 4, fits the 0x2000 mapping. The definitions match `drivers/gpu/drm/tegra/dc.h:197,203,246,395`.

I do not see a material parsing bug. The nine `clk_summary` tokens match the kernel's emitted columns (`drivers/clk/clk.c:3274-3301`), and the genpd parser correctly ignores indented device rows while retaining non-indented domain rows (`drivers/pmdomain/core.c:3824-3894`). The fixed append buffers can truncate silently, but the selected T210 names fit; this is not likely to affect the run.

CAR reads are safe. DC A is read only if DISP1 is clocked and out of reset (`tools/darcy-init.c:195-203`; U-Boot patch lines 618-624), and DC itself is not in `pd_sor`. A powered-off MMIO target can cause an external abort on some Tegra interconnect states, so absolute safety is **UNCERTAIN**, but the existing DC guard is appropriate and this access is unlikely to hang the CPU. Do not add Linux-side SOR MMIO reads unless `sor=yes`, SOR1's clock is on, and its reset is clear.

One coverage gap: the raw list omits CILAB/CILCD/CILE and DSIB even though `pd_sor` controls them. It does include every block needed to prove the HDMI failure, especially SOR1 and DPAUX1.

## 3. Highest-value additions within the 56-line budget

The existing run is already sufficient to confirm the PMC theory. If changing it, add only compact lines near the very end:

1. Print PMC `PWRGATE_STATUS` before Linux and at 60 s, decoding SOR bit 17 plus DIS/DISB bits 18/19. The register is 0x38 (`drivers/soc/tegra/pmc.c:93,590-595`; U-Boot's `pmc.h:366-385`). Linux debugfs already supplies the post-state, but the pre-state makes the A/B explicit.
2. Print PLL_D2 MISC0..3 (0x4bc, 0x570, 0x574, 0x578), not only BASE. If space permits, add PLLD MISC0/1 and PLLDP MISC/SS registers listed at `clk-tegra210.c:71-97,149-153`.
3. Print pinmux words 0x70003198 and 0x7000319c on both sides. This settles the parked-bit fallback in one line.
4. If investigating MC later, add `DC_CMD_INT_STATUS` (word 0x037) and window-A `DC_WINBUF_UFLOW_STATUS` (word 0x80a; `dc.h:212,716`). The latter lies beyond the current 0x2000 mapping, so enlarge that map before reading it.

Keep `show_powergates()`, `show_genpd()`, clock summary, and raw CAR/DC as the final lines. If more output is added, reduce `HIGHLIGHTS` from 30 to about 18 rather than pushing these decisive lines off the photographed screen.

## 4. Candidate fix for the same image

I would combine the diagnostics with a narrow preserve-SOR fix rather than spend a run merely proving what the source already makes deterministic.

Best experimental fix: add a darcy-only DT property to `pd_sor`, then make `tegra_powergate_add()` honor it by, when PMC reports the domain already on:

- skipping `tegra_powergate_power_down()`;
- calling `pm_genpd_init(..., is_off=false)`; and
- adding `GENPD_FLAG_ALWAYS_ON` alongside `GENPD_FLAG_NO_SYNC_STATE`, so later provider sync cannot shut it down.

This changes one causal path while retaining PMC, powergate debugfs, and all of `aa661a8`'s diagnostics. If HDMI survives and the dump shows `sor on`, SOR1 enabled/reset-clear, and matching DC/PLL state, the diagnosis is strong.

A simpler one-boot differential is `&tegra_pmc { status = "disabled"; };`. That avoids the destructive platform probe while leaving cboot's state intact, but it removes the powergate/genpd diagnostics and causes power-domain consumers to defer; use it only as a temporary simplefb test. Linux reboot should still use PSCI and U-Boot already set the recovery scratch bit, but that exact disabled-PMC path is **UNCERTAIN**.

Do not merely set `status = "disabled"` on `pd_sor`: `tegra_powergate_init()` uses `for_each_child_of_node_scoped`, not the available-child iterator, so it still processes disabled children (`pmc.c:1520-1530`). Deleting `pd_sor` also requires removing every remaining `<&pd_sor>` reference or the DT will contain unresolved references.
