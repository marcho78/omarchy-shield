# Review brief: HDMI through tegra-drm on darcy (SHIELD TV 2017)

**Analysis only.** Do not change any file in the repository and do not touch
the device. Repository: `~/projects/nvidia` (read `NOTES.md` for history).
Kernel source: `vendor/linux` (Linux 7.2.11). Stock NVIDIA darcy device tree:
`vendor/lineage-t210-foster/kernel-dts`, `vendor/lineage-t210-common/kernel-dts`.

Cite `file:line` for every claim about code. Say plainly when something is a
guess. Earlier rounds had confident claims that the source contradicted; a
short answer with checked claims beats a long one with unchecked ones.

## Goal of this step

tegra-drm drives HDMI (SOR1) itself, so the desktop (Hyprland, later
Omarchy) gets a KMS device. The first test must keep today's safety: the
console on cboot's picture and SSH over Wi-Fi.

## Where things stand (checked)

- Boot chain: cboot → our U-Boot → mainline Linux 7.2.11 → Arch Linux ARM
  on a USB SSD. The console is on simpledrm, on the framebuffer cboot left
  running (1080p59.94, PLL_D2 148.35 MHz, DC A → SOR1). SSH works.
- Today `module_blacklist=tegra_drm` is on the command line. When tegra-drm
  loaded (first boot), it removed simpledrm
  (`aperture_remove_all_conflicting_devices`, `drivers/gpu/drm/tegra/drm.c`)
  and then found no output, "Cannot find any crtc or sizes", because DPAUX1,
  SOR1 and I2C4 are disabled in the DT. The TV went dark.
- **Our DT deletes the SOR powergate** (`/delete-node/ &pd_sor` and every
  `power-domains = <&pd_sor>`, `kernel/dts/darcy.dts`): `tegra_powergate_add()`
  (`drivers/soc/tegra/pmc.c`) powers down every partition that is on at PMC
  probe, which killed cboot's HDMI. So SOR1, SOR0, DPAUX, DPAUX1, DSI, the
  HDA and the CSI have no power domain; the SOR partition stays as cboot set
  it (on).
- The PMC is TZ-only on this board; mainline goes through the secure monitor
  (`maybe_tz_only`, `pmc.c`). Earlier runs read real values that way.
- Tegra210 DC: `has_powergate = true` (`dc.c`, `tegra210_dc_soc_info`), so
  the DC uses the legacy powergate API (DIS/DISB).
- Kernel config: `DRM_TEGRA=m`, `TEGRA_HOST1X=m`, `I2C_TEGRA=y`,
  `DRM_FBDEV_EMULATION=y`, `FRAMEBUFFER_CONSOLE=y`, `TEGRA_IOMMU_SMMU=y`,
  `DRM_SIMPLEDRM=y`, `GENERIC_PINCONF=y`, `DEVMEM=y`. host1x and tegra-drm's
  helper modules already load at boot today; only tegra_drm is refused.
- `/lib/firmware/nvidia/tegra210/vic04_ucode.bin` is present.

**Live hardware state, read on the SHIELD over SSH** (`tools/mmio-read.c`,
mmap of `/dev/mem`; SOR1 was checked clocked and out of reset first:
`CLK_OUT_ENB_X` bit 23 = 1, `RST_DEVICES_X` bit 23 = 0):

| SOR1 register (index) | cboot's value | decoded | mainline Tegra210, 150 MHz entry (`sor.c:60`, `#if 1`) |
|---|---|---|---|
| STATE1 (0x04) | `0x00040141` | owner head 0, TMDS A | |
| head_state1 (0x07) | `0x04650898` | 1125 × 2200 (1080p) | |
| PLL0 (0x17) | `0x010003c0` | ichpmp 1, vcocap 3 | ichpmp 1, vcocap 3 |
| PLL1 (0x18) | `0x00301300` | loadadj 3, termadj 9, TMDS_TERM | loadadj 3, termadj 9 |
| PLL3 (0x1a) | `0x38000440` | bg_temp 3, bg_vref 8, avdd14 4, avdd10 4 | 3, 8, 4, 4 |
| XBAR_CTRL (0x4a) | `0x8d111828` | LINK0 {2,1,0,3,4}, LINK1 identity | default {2,1,0,3,4} (`sor.c:3498`, written in `tegra_sor_hdmi_enable()` at `sor.c:2389`): **identical value** |
| LANE_DRIVE_CURRENT0 (0x4e) | `0x2d303030` | lanes 0-2 0x30, lane 3 0x2d | `0x3a3a3a33` (lane 0 0x33, lanes 1-3 0x3a) |
| LANE_PREEMPHASIS0 (0x52) | 0 | | 0 |
| DP_PADCTL0 (0x5c) | `0x00c0660f` | TX_PU 0x66 | 0x66 |
| HDMI_CTRL (0xc0) | `0x40060038` | enabled, rekey 56 | |
| INPUT_CONTROL (0xe8) | `0x2` | limited RGB range | |
| HDMI2_CTRL (0x13e) | `0x02000080` | no scrambling | |

cboot's drive current equals the stock darcy prod for 54–300 MHz
(`foster-platforms/tegra210-darcy-prods.dtsi`); mainline's table is the
Jetson TX1's. Mainline does not read prods from the DT.

GPIO port CC (bank 7 port 0, `0x6000d700`): CNF `0xb2`, OE `0xb0`, OUT
`0x90`, IN `0x10`. CC1 (hot-plug) is a GPIO input reading **0** with the TV
connected; CC7 (HDMI 5V enable) is a GPIO output driven **1**.

Clock framework (`clk_summary`): sor1, sor1_out, sor_safe, dpaux1, pll_d2,
pll_d2_out0, disp1 hardware-enabled, nothing holding them
(`clk_ignore_unused`); pll_dp off.

**The stock darcy DT** (`tegra210-ers-hdmi-e2190-1100-a00.dtsi`, darcy's
power tree, `tegra210-ers-fixed-e2174-1101-a00.dtsi:103`): SOR1 with DDC on
`i2c@7000c700` at 100 kHz, hot-plug `TEGRA_GPIO(CC, 1)` active low, parent
`pll_d2`, DC A → sor1; `avdd_hdmi` = ldo8, `avdd_hdmi_pll` = sd3,
`vdd_hdmi_5v0` = `vdd_hdmi` (fixed 5 V, GPIO CC7 active high, boot-on, from
`vdd_sys_boost`). Mainline's `tegra210-p2894.dtsi` defines `vdd_hdmi` the
same way, and has no display nodes.

**Mainline's recipe on the same SoC** (`tegra210-p2597.dtsi`, Jetson TX1;
`tegra210-p3450-0000.dts`, Nano): DPAUX1 okay; SOR1 okay with
`avdd-io-hdmi-dp-supply`, `vdd-hdmi-dp-pll-supply`, `hdmi-supply`,
`nvidia,ddc-i2c-bus`, `nvidia,hpd-gpio = CC1 active low` (Nano adds
`nvidia,xbar-cfg = <0 1 2 3 4>`); `hdmi_ddc: i2c@7000c700` okay at 100 kHz.

## The proposed change (not flashed)

The diff: `/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/hdmi-drm.diff`
(against commit 1726fc4). In short:
1. `darcy.dts`: DPAUX1 okay; SOR1 okay with ldo8 / sd3 / vdd_hdmi, DDC on
   I2C4, HPD CC1 active low, no xbar override; `hdmi_ddc: i2c@7000c700` okay
   at 100 kHz; `vdd_hdmi` no longer disabled (boot-on, so
   `regulator/fixed.c:191,295` requests CC7 high).
2. `darcy-system.dts`: `module_blacklist=tegra_drm` out (it would refuse a
   manual `modprobe` too); `video=HDMI-A-1:1920x1080@60` in.
3. Root filesystem (`scripts/13`, and put on the running system by hand
   before the flash): `/etc/modprobe.d/20-darcy-tegra-drm.conf` with
   `blacklist tegra_drm`, so udev does not load it at boot.

**The test, all over SSH:**
1. Flash the new boot image (`scripts/17`). It boots as today: simpledrm,
   console on the TV.
2. `echo Y > /sys/module/printk/parameters/ignore_loglevel`, so that the
   ramoops console (which U-Boot shows after a crash) gets everything; the
   system normally runs with `kernel.printk = 3 4 1 7`.
3. `modprobe tegra_drm`. Expected: the TV blanks (the DC probe powers DIS
   off), then the console comes back through tegra-drm's fbdev at 1080p.
4. Collect: `dmesg`, `/sys/class/drm/card*-HDMI-A-1/{status,modes,edid}`,
   tegra-drm's debugfs SOR registers against the table above.
5. Way back: reboot over SSH. If it hangs, systemd's watchdog (60 s,
   `tegra_wdt`) resets the board; U-Boot then shows the ramoops log and
   goes to the bootloader menu, from where `scripts/14` reflashes.

## Questions

1. **No SOR power domain.** With `pd_sor` gone, do `sor.c`, `dpaux.c` and
   `dc.c` still bring HDMI up? Any path that needs genpd, or that calls the
   SOR powergate through the legacy API?
2. **The DC's legacy powergate on a TZ-only PMC:** does
   `tegra_powergate_power_off()` / `tegra_powergate_sequence_power_up()`
   (DIS, DISB) work through the secure monitor in this kernel? Anything
   else on the modeset path that writes PMC registers directly (IO pad
   DPD for `TEGRA_IO_PAD_HDMI`, `sor.c:2283`)?
3. **I2C4's pinmux lives in DPAUX1** (`state_dpaux1_i2c`), which tegra-drm
   (a module) registers, while `i2c-tegra` is built in. What happens at
   boot (deferral, fw_devlink, the deferred-probe timeout), and does SOR1
   then get its DDC adapter when tegra-drm loads? Is the order safe?
4. **vdd_hdmi:** any way its probe glitches CC7, or another consumer turns
   it off?
5. **Drive current:** is mainline's higher setting a risk for a first
   picture at 1080p, or should darcy's values be patched into `sor.c`
   first?
6. **`video=HDMI-A-1:1920x1080@60`:** right connector name for tegra-drm's
   SOR HDMI, and does fbdev honour it? Is pinning 1080p wise for the first
   test?
7. **modprobe.d `blacklist`:** confirm udev will not load tegra_drm by
   alias and `modprobe tegra_drm` by name still works.
8. **Anything that can make this test unrecoverable without the TV:** for
   example, a hang the watchdog does not catch, or losing SSH with no reset.
9. **Anything missing** for HDMI on SOR1 in mainline Tegra210 that the
   Jetson boards have and darcy's DT lacks (clocks, `nvidia,head`,
   `nvidia,outputs`, assigned-clocks, the SOR safe clock, VIC, the SMMU).

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-hdmi-drm-<your name>.md`
(`ncodex`, `ngrok`, `zai` or `antigravity`) and reply with only that path.
