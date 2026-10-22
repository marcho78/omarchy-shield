# HDMI link drop after the console appears

Run 3 closed the PMIC. The rails stay up for the whole 60 s, and the TV reports no signal rather than a black frame, so the thing that stops is the TMDS clock out of SOR1. `clk_ignore_unused` and `pd_ignore_unused` only skip the late unused passes (`drivers/clk/clk.c:1524` and `drivers/pmdomain/core.c:1371`). They do not stop probe.

The flicker at 1.45 s is simpledrm mapping the reserved framebuffer (`simpledrm` does not program DC or SOR). The code that takes the link down runs earlier, in PMC probe, next to the 0.156 s `tegra-pmc` lines.

## 1. Hypotheses

### 1. PMC powers the `sor` domain down and asserts its resets

This is the one that matches a link that dies and stays dead while the rails and PLL_D2 can still look fine.

`pd_sor` is in the stock DT (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:941-960`). `darcy.dts` does not remove it. Its clocks are SOR0, SOR1, CILAB, CILCD, CILE, DSIA, DSIB, DPAUX, DPAUX1, MIPI_CAL. Its resets are SOR0, SOR1, DSIA, DSIB, DPAUX, DPAUX1, MIPI_CAL. SOR1's own node is `status = "disabled"` (`tegra210.dtsi:336-353`) and its pixel-clock parent is `PLL_D2_OUT0` (`:342`). The domain is registered anyway. `tegra_powergate_init` walks every child (`drivers/soc/tegra/pmc.c:1520-1525`).

`tegra_powergate_add` (`pmc.c:1347-1391`) does this for each child:

- If the SMC says the partition is off, it asserts that domain's resets (`:1367-1371`).
- If the SMC says it is on, it calls `tegra_powergate_power_down` (`:1373-1379`). That enables the domain clocks, asserts the resets, disables the clocks, then asks the secure monitor to power the partition off (`:895-919`).
- It then registers the genpd as already off (`pm_genpd_init(..., true)` at `:1391`).

cboot is scanning out, so the partition should read as on, and the second branch runs. Either branch leaves SOR1's reset bit set. Nothing turns the domain back on: DRM and HOST1X are modules and are absent, and `pd_ignore_unused` only skips a later pass over domains that are still on. The MBIST workaround that clocks DISP1 (`clk-tegra210.c:2638-2678`) runs from `tegra_powergate_power_up` (`pmc.c:868`), not on the way down.

DISP1 is not in `pd_sor`'s clock or reset list, so display controller A can stay clocked and still hold cboot's programming. The sink loses TMDS because SOR1 is in reset. That is a "No signal", with the controller's framebuffer left intact.

There was no `failed to turn off PM domain` line in the three runs. That string contains `fail`, which darcy-init keeps. So the power-down returned, or the partition already read as off and only the reset assert ran. Both leave the reset bit set. There was also no `SMC failed` line (`pmc.c:539`).

**In the dump:** `powergates off:` contains `sor`. `power domains:` shows `sor off-0` (`off-0` is the off state, `drivers/pmdomain/core.c:3842-3844`). The clock line shows `SOR1 0/1`, and the same `0/1` for `DPAUX`, `DPAUX1`, `DSIA`, `MIPI_CAL`. `DISP1` can still be `1/0`, and `DC A:` can still show cboot's command word. `PLLs: D2` can still have bit 30 set. That combination is this hypothesis. If `SOR1` is `1/0` and `sor` is on, drop it.

### 2. PLL_D2 defaults, only if cboot left the PLL disabled

`tegra210_plld2_set_defaults` runs while the clock driver registers (`clk-pll.c:1921-1922`, called from `tegra_clk_register_pllss_tegra210` at `clk-tegra210.c:3404`). `plldss_defaults` (`clk-tegra210.c:936-1024`) reads `PLLD2_BASE` (`0x4b8`). Bit 30 is the enable (`clk-tegra210.c:322`).

- Enable set: it does not set IDDQ. It may clear lock-override (bit 24 of BASE) and set lock-enable (bit 30 of `PLLD2_MISC0` at `0x4bc`). The comment says those are in-flight writes. They are a poor fit for a link that stays dead for 60 s.
- Enable clear: it sets IDDQ (bit 18 of BASE, `PLLDSS_BASE_IDDQ` at `:368`) and rewrites MISC0-3. That kills the PLL. HDMI's parent is PLL_D2, so this kills TMDS.

cboot is driving HDMI, so bit 30 should be set and this path should take the first branch. Same function for PLL_DP (`:1034`). PLL_D's IDDQ lives in `PLLD_MISC0` bit 20 (`:357`), and `tegra210_plld_set_defaults` (`:883-929`) likewise IDDQs only when PLL_D is off. Clock init also clears bit 25 of `PLLD_BASE` unconditionally (`:3800-3803`, the DSI source select). Expect `PLLs: D` to differ in bit 25 even when HDMI was never using PLL_D.

The init table (`:3551-3606`, applied from `tegra210_clock_apply_init_table` at `:3617`) does not disable PLL_D2. It sets PLL_DP to 270 MHz with state 0, which calls `clk_set_rate` and does not enable (`clk.c:292-305`). It reparents HOST1X to `pll_p` at 136 MHz and enables it (`:3563`). HOST1X is the register bus. Changing it does not reset SOR.

**In the dump:** hypothesis 2 is confirmed only if `D2`'s word has bit 18 set or bit 30 clear, against a U-Boot word with bit 30 set. A D2 word that matches U-Boot except bit 24, with `SOR1` in reset, is hypothesis 1. A changed `DP` word with `D2` intact is the init table, and it is not the HDMI parent.

### 3. Parked-bit clear on the HPD pin

`tegra_pinctrl_clear_parked_bits` (`drivers/pinctrl/tegra/pinctrl-tegra.c:731-751`, called at `:929`) clears `parked_bitmask` on every group. On T210 that mask is bit 5 (`pinctrl-tegra210.c:1316`). The HDMI pins in that table are CEC and HPD (`hdmi_cec_pcc0` at `:1453`, register `0x3198`; `hdmi_int_dp_hpd_pcc1` at `:1454`, register `0x319c`). The TMDS pairs are not pinmux pins. Clearing bit 5 can change the HPD pad. It cannot reset SOR. Rank it under 1 and 2. The dump will not show it. If `SOR1` is still `1/0`, PLL_D2 matches U-Boot, and `sor` is on, this is the next thing to read.

### 4. MC latency allowance and the SMMU

MC probe writes every client's latency allowance (`drivers/memory/tegra/mc.c:414-441`). That can starve a client. It does not reset SOR or stop a TMDS clock. The SMMU strict-mode line is at 0.118 s, and a DC translation fault paints black or garbage while the sink still has a clock. Both are a poor fit for "No signal". `sync_state() pending` for host1x at 12 s means the MC did not cut that client later. **In the dump:** CAR, PLL_D2, and the `sor` powergate all match U-Boot. Treat that as the leftover bucket.

### 5. XUSB padctl

`padctl@7009f000` and `usb@70090000` are `status = "disabled"` (`tegra210.dtsi:1113`, `:1124`). The padctl driver does not probe. The xusb powergates are still registered, because they sit in the same `powergates` node as `sor`, and hypothesis 1 applies to them too. They do not own the HDMI pins.

### Not the cause

simpledrm produced the flicker and never programs SOR. `cpufreq` `-2` is `-ENOENT`. `cpuidle.off=1` accounts for the idle failure. IRQ74 trimming is `kernel/irq/irqdomain.c` dropping an unused parent, and virq 74 is not the DC B SPI. The gpio7 nonexclusive line and the 33.81 s regulator line show the ignore flags working. The PMIC values are the stock ones and the rails were on at 60 s.

## 2. The diagnostics in aa661a8

Offsets and IDs are the T210 ones.

| What | Value | Where |
|---|---|---|
| DISP2, DISP1, HOST1X, DSIA, MIPI_CAL | 26, 27, 28, 48, 56 | `include/dt-bindings/clock/tegra210-car.h:46-48`, `:69`, `:77` |
| DPAUX, SOR0, SOR1, DPAUX1, SOR_SAFE | 181, 182, 183, 207, 222 | `:207-209`, `:234`, `:249` |
| CLK_OUT_ENB L/H/U/V/W/X/Y | 0x010, 0x014, 0x018, 0x360, 0x364, 0x280, 0x298 | used by both sides |
| RST_DEVICES | 0x004, 0x008, 0x00c, 0x358, 0x35c, 0x28c, 0x2a4 | same |
| PLLD / PLLD2 / PLLDP bases | 0x0d0, 0x4b8, 0x590 | `clk-tegra210.c:71`, `:87`, `:96` |
| CLK_SOURCE_DISP1, CLK_SOURCE_SOR1 | 0x138, 0x410 | `clk-tegra-periph.c:78`, `clk-tegra210.c:35` |
| DC command / power / state / clock | words 0x032, 0x036, 0x041, 0x42e | `drivers/gpu/drm/tegra/dc.h` |

IDs below 224 are the CLK_OUT_ENB bits (`tegra210-car.h:5-11`). The reset driver writes `BIT(id % 32)` in that bank (`drivers/clk/tegra/clk.c:113-115`), which is the bit both dumps read back. Bank `id/32` is right for all ten. The shared-bit exceptions in that header are other IDs.

U-Boot `dc_readl` is `readl(DC_BASE + reg * 4)` (`board/nvidia/p2894/p2894.c:194-196`). darcy-init indexes a `uint32_t` map (`tools/darcy-init.c:199-201`). The two DC lines are the same registers. CAR reads are `readl(0x60006000 + offset)` on one side and `car[offset/4]` on the other.

Nothing here should hang the CPU. CAR and the PLL bases are in the always-on clock aperture. The map is 0x1000 and the highest offset used is `PLLDP_BASE` 0x590. The DC read is skipped unless DISP1's enable bit is set and its reset bit is clear (`darcy-init.c:195-203`, and the same test in `p2894.c:394-395`). DISP1 is not inside `pd_sor`, so that guard still holds if hypothesis 1 is right. A failed `mmap` prints `cannot map the CAR` and returns. `IO_STRICT_DEVMEM` is off, so `/dev/mem` can map these apertures.

Parsing matches this tree.

- `powergate_show` prints ` %9s %7s` with `yes`/`no` (`pmc.c:1234-1243`). The sscanf keeps `yes` and skips the header. A missing name means the SMC read returned an error (`:1238-1240`), not that the partition is off.
- `pm_genpd_summary` prints the genpd name (`sor`, from the node name) and `off-0` or `on` (`core.c:3842-3848`). Device lines are indented and skipped. `off-0` is off.
- `clk_summary` is nine columns: name, enable, prepare, protect, rate, accuracy, phase, duty, hw enable (`clk.c:3281-3301`). darcy-init prints enable, rate, and the Y/N hw column. Header lines do not match the clock names. The first match wins, which is what we want.

The 300-byte half-lines can truncate the last clock of a half. That drops a name. It does not overflow. `clk_summary_show` takes a runtime reference and recalculates rates (`clk.c:3336-3347`). No display driver is bound, so that read should not reprogram SOR. `show_display_hw` is already last (`darcy-init.c:415-419`), which is the right order for the 56-line screen.

Decode the raw words on the photo:

- PLL_D2 bit 30 enable, bit 18 IDDQ, bit 24 lock-override.
- `SOR1 src` bits [31:29] are the parent: 0 `pll_p`, 2 `pll_d_out0`, 5 `pll_d2_out0`, 6 `clk_m` (`clk-tegra210.c:3020-3024`). Bits [7:0] are the divider. DISP1 uses the same parent indices (`clk-tegra-periph.c:574-578`).

## 3. What else to capture

This run already has the deciding comparison: U-Boot versus Linux for the SOR1 reset bit, the `sor` powergate, and the PLL_D2 base. Run it as it is.

Do not read SOR1 at `0x54580000` on this image. If hypothesis 1 is right, that block is held in reset, and a read there can wedge the CPU before the watchdog reboot. The CAR reset bit is the SOR state this photo needs. `SOR_STATE1` is word `0x04` and `SOR_PLL0` is word `0x17` (`drivers/gpu/drm/tegra/sor.h:23`, `:87`) if a later image reads them, and only while the SOR1 clock bit is 1 and the reset bit is 0.

If this photo shows `SOR1 1/0`, `sor` on, and PLL_D2 bit 30 set with bit 18 clear, the next image should add two CAR words and one pin word, still without touching SOR:

- `PLLD2_MISC0` at `0x4bc` (lock-enable is bit 30). MISC1/2/3 are `0x570`, `0x574`, `0x578`.
- Pinmux `0x319c` (HPD) and `0x3198` (CEC), bit 5.

Keep those lines last. A full `clk_summary` will blow the 56-line window.

## 4. Keep this image diagnostic

Do not put a fix in the image that produces this photo. Removing `pd_sor` would change the same reset bit the two dumps exist to compare, so a picture coming back would not say whether the reset, the PLL, or the pin did it.

If the photo shows `sor` off and `SOR1 0/1`, the next image's single change is to stop registering that domain: `/delete-node/ &pd_sor;` from `darcy.dts` (the node is `tegra210.dtsi:941-960`). Leave `clk_ignore_unused` and `pd_ignore_unused` in place, and do not also hold PLL_D2 or the SOR1 mux. A live link on that image is the powergate. Leave the PMC driver and the clock driver enabled.
