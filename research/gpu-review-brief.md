# Review brief: the GPU (GM20B, nouveau) on darcy (SHIELD TV 2017)

**Analysis only.** Do not change any file in the repository and do not touch
the device. Repository: `~/projects/nvidia` (`NOTES.md` has the history; the
HDMI round is `research/*hdmi-drm*`). Kernel: `vendor/linux` (7.2.11). Stock
NVIDIA darcy device tree: `vendor/lineage-t210-foster/kernel-dts`,
`vendor/lineage-t210-common/kernel-dts`.

Cite `file:line` for every claim about code, and say plainly when something
is a guess. Last round, a confident claim that the command line lacked
`regulator_ignore_unused` was wrong; check the actual files.

## Goal of this step

nouveau brings up the GM20B, so the desktop gets hardware rendering (Mesa
`tegra` + `nouveau`, with tegra-drm doing the display). First test: load
nouveau by hand over SSH, with today's safety (console on tegra-drm, SSH over
Wi-Fi) and a sysrq reboot timer armed, as for HDMI.

## Where things stand (checked)

- Boot chain: cboot → our U-Boot → mainline Linux 7.2.11 → Arch Linux ARM on
  a USB SSD. tegra-drm drives HDMI from boot (1080p60).
- Silicon: "Tegra Revision: A02 SKU: 135", the same revision as Jetson TX1.
- Kernel config: `DRM_NOUVEAU=m`, `NOUVEAU_PLATFORM_DRIVER=y`,
  `REGULATOR_PWM=y`, `PWM_TEGRA=m`, `TEGRA_IOMMU_SMMU=y`.
- Firmware: `/lib/firmware/nvidia/gm20b/{acr,gr,pmu}/*` from
  `linux-firmware-nvidia 20260916-1`.
- The PMC is TZ-only; every PMC access goes through the secure monitor
  (`tegra_pmc_readl/writel`, `drivers/soc/tegra/pmc.c:530-571`). Already
  exercised that way on darcy, with no "SMC failed" in any kept boot:
  `PMC_SCRATCH0` (reboot reason), `PWRGATE_TOGGLE`/`REMOVE_CLAMPING` (XUSB's
  genpd), `IO_DPD_REQ` (PCIe pads), and the DIS/DISB powergates and HDMI pad
  (tegra-drm).

**Mainline's GPU node** (`tegra210.dtsi:440-457`): `nvidia,gm20b`, clocks
gpu / pll_p_out5 / pll_g_ref, reset 184, `iommus`, no `power-domains`,
disabled. Jetson TX1 (`tegra210-p2180.dtsi:32-35, 426-436`) and Nano
(`tegra210-p3450-0000.dts:112-115, 1858-1870`) enable it with
`vdd-supply = <&vdd_gpu>`:

```
vdd_gpu: regulator-vdd-gpu {
	compatible = "pwm-regulator";
	pwms = <&pwm 1 8000>;
	regulator-name = "VDD_GPU";
	regulator-min-microvolt = <710000>;
	regulator-max-microvolt = <1320000>;
	enable-gpios = <&pmic 6 GPIO_ACTIVE_HIGH>;
	regulator-ramp-delay = <80>;
	regulator-enable-ramp-delay = <2000>;
	regulator-settling-time-us = <160>;
};
```

**darcy's stock GPU rail is the same circuit:** `gpu_ovr_reg`
(`t210-common-platforms/tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:110-123`,
included by darcy's power tree,
`foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi:18-20`):
`pwm-regulator`, `pwms = <&tegra_pwm 1 8000>`, 710000–1320000 µV,
`regulator-n-voltages = <62>`, enable ramp 2000, settling 160,
`enable-gpio = <&max77620 6 0>`. Nothing in darcy's chain overrides it, nor
the GPU node. The I2C GPU regulator in the e2174 PMIC file is
`status = "disabled"`. Polarity is not measured: no INA3221 channel watches
VDD_GPU (`foster-platforms/tegra210-foster-powermon-p2530-0930-e0*.dtsi`).
The same family's CPU OVR has an explicit table, duty step 0 = 708 mV up to
step 32 = 1322.4 mV (`...e2174-1101-a00.dtsi:86-107`).

**Live state on the SHIELD now** (read-only: debugfs regmap, clk_summary,
mmap of `/dev/mem` after checking clock/reset bits):
- GPU clock off (clk_summary `gpu` hardware enable N).
- PMIC GPIO 6 (`CNFG_GPIO6` = `0x03`): push-pull, **input**, reading low,
  so the rail is off (`include/linux/mfd/max77620.h:211-220` for the bits).
  The PMIC's pinctrl already sets gpio5/6/7 to the GPIO function
  (`tegra210-p2894.dtsi:1409-1413`).
- PWM controller `pwm@7000a000` clocked and out of reset. Channel 0 CSR
  `0x80ff00bb` (enabled, ~100% duty); channels 1–3 `0`.
  - channel 0 = the lightbar LED (`pwm-leds` / `led_lightbar`,
    `tegra210-darcy-p2894-common.dtsi:343-347`)
  - channel 1 = the GPU rail
  - channel 3 = a fan (`pwm-fan`); the 2017 SHIELD has none, and its pin
    isn't muxed
- **The GPU PWM pin `lcd_gpio2_pv4` (pinmux `0x7000320c`) reads 0: function
  DISPLAYB, not PWM1.** The stock darcy DT muxes it to `pwm1` as part of its
  `default` pinmux (`tegra210-darcy-pinmux-p2894-0000-a00.dtsi:24-25,
  117-123`), which Android's kernel applies. Mainline's p2894 has `pwm1`
  for it only in the `boot` state (`tegra210-p2894.dtsi:881-888`), and the
  pinctrl core applies only `default` (`NOTES.md`). `lcd_bl_pwm_pv0` (LED)
  is on PWM0.
- `pwm-tegra`: probe sets the clock to 48 MHz (already 48 MHz) and only
  deasserts the reset (`drivers/pwm/pwm-tegra.c:300-341`). Runtime suspend
  gates the controller's clock (`pwm-tegra.c:362-377`) whenever no Linux
  user has a channel on.

**nouveau's Tegra power-up** (no `pm_domain`,
`nvkm/engine/device/tegra.c`): regulator_enable(vdd) → clocks gpu, ref, pwr
(pwr set to 204 MHz) → reset assert → `tegra_pmc_powergate_remove_clamping(
3D)` → reset deassert. On Tegra210 (`has_gpu_clamps`) that writes 0 to
**`GPU_RG_CNTRL` (PMC `0x2d4`)** (`pmc.c:713-747`). That offset has never
gone through the secure monitor here; `tegra_pmc_writel` only warns if an
SMC fails, and clamp removal returns 0 either way. The upstream TF-A
Tegra210 SiP PMC handler blacklists only some scratch registers and a few
secure-only ones; NVIDIA's monitor on this board is not available to read.

**GM20B secure boot:** `gm20b_acr_wpr_alloc()` takes the WPR bounds from the
GPU's FB register `0x100cd4` (`nvkm/subdev/acr/gm200.c:53-61`), which the
secure boot firmware programs; darcy's firmware is the one Android's nvgpu
runs on. If the WPR is missing, nouveau logs "WPR image too big for WPR!".

**Userspace:** Mesa 26.2.5 and mesa-utils (eglinfo) are in Arch Linux ARM's
repos; glmark2 too; kmscube is not. Not installed yet. pacman on the device
could not download at all: pacman 7's sandbox needs Landlock, missing from
the kernel. `CONFIG_SECURITY_LANDLOCK=y` is being built now (`CONFIG_LSM`
already lists `landlock`).

## The proposed change (not flashed)

Added to `kernel/dts/darcy.dts`:

```
&pinmux {
	gpu_pwm_default: pinmux-gpu-pwm {
		lcd_gpio2_pv4 {
			nvidia,pins = "lcd_gpio2_pv4";
			nvidia,function = "pwm1";
			nvidia,pull = <TEGRA_PIN_PULL_NONE>;
			nvidia,tristate = <TEGRA_PIN_DISABLE>;
			nvidia,enable-input = <TEGRA_PIN_DISABLE>;
		};
	};
};

&pwm {
	pinctrl-names = "default";
	pinctrl-0 = <&gpu_pwm_default>;
	status = "okay";
};

/ {
	vdd_gpu: regulator-vdd-gpu {
		compatible = "pwm-regulator";
		pwms = <&pwm 1 8000>;
		regulator-name = "vdd-gpu";
		regulator-min-microvolt = <710000>;
		regulator-max-microvolt = <1320000>;
		enable-gpios = <&pmic 6 GPIO_ACTIVE_HIGH>;
		regulator-ramp-delay = <80>;
		regulator-enable-ramp-delay = <2000>;
		regulator-settling-time-us = <160>;
	};
};

&{/gpu@57000000} {
	vdd-supply = <&vdd_gpu>;
	status = "okay";
};
```

Root filesystem: `/etc/modprobe.d/` gets `blacklist nouveau` and
`install nouveau /bin/true` (the HDMI round showed a blacklist alone misses
soft dependencies), until the test passes.

**The test, over SSH:**
1. Flash, boot. Expect: pwm-tegra binds, `lcd_gpio2_pv4` becomes PWM1,
   vdd-gpu registers and stays off (GPIO 6 output low), nouveau not loaded.
2. Arm a 3-minute sysrq reboot (`systemd-run --on-active=180 ... echo b >
   /proc/sysrq-trigger`), `ignore_loglevel` on.
3. `modprobe --ignore-install nouveau`; collect dmesg, the regulator state
   and voltage, `/sys/kernel/debug/dri/*`, the PWM channel 1 CSR.
4. Install `mesa mesa-utils glmark2`; `eglinfo -p gbm`, then
   `glmark2-es2-drm` on the TV.

## Questions

1. **Is the rail right for darcy?** Anything in the stock darcy chain, or in
   the downstream pwm-regulator semantics (`regulator-n-voltages`, no
   `pwm-dutycycle-range`), that would make mainline's continuous mode map
   duty to voltage differently (polarity, offset) than on Jetson TX1?
2. **The PWM pin:** is `pwm` `default` state the right place for it?
   `pwm-tegra` selects the default/sleep states at runtime resume/suspend.
   Any glitch on the OVR input when the pin switches from DISPLAYB to PWM1
   while the rail is off?
3. **`GPU_RG_CNTRL` through the monitor:** how likely is the monitor to
   refuse it, and what happens next in nouveau if the clamp stays (bus
   hang/SError on the first GPU register access, or something softer)?
   Is there a safe read-only way to probe that offset first?
4. **nouveau's power-up order on GM20B:** at what voltage and clock does
   nouveau first touch the GPU after `regulator_enable`, given the
   pwm-regulator starts at 710 mV (channel 1 disabled at probe)? Is that
   the same as on Jetson TX1?
5. **Voltage table:** nouveau's gm20b volt/clk tables by speedo
   (`nvkm/subdev/volt/gm20b.c`, `clk/gm20b.c`): does anything need the
   fuses or the DT beyond what darcy has?
6. **The LED:** confirm that only channel 0's output freezes (no other
   side effect) when the controller's clock is gated.
7. **The WPR:** anything else nouveau needs from the bootloader on GM20B
   (MC carveouts, `nvidia,` properties) that Jetson TX1's cboot provides?
8. **Userspace:** does Mesa's `tegra` gallium driver (render-only, with
   nouveau) work for GBM/EGL on the tegra-drm card in current Mesa, and is
   it in Arch Linux ARM's mesa build? Is `glmark2-es2-drm` a sound first
   visible test?
9. **Anything that can make this unrecoverable without the TV**, beyond
   what the HDMI round covered.

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-gpu-<your name>.md`
(`ncodex`, `ngrok` or `antigravity`) and reply with only that path.
