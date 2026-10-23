# GPU (GM20B) review

Analysis only. Nothing in the repository was changed and the device was not touched. The proposed fragment is the one in the brief; `kernel/dts` has no `vdd_gpu` node. `regulator_ignore_unused` is not re-litigated here.

SKU 135 is `0x87`. On A02 that is `gpu_speedo_id` 1 (`drivers/soc/tegra/fuse/speedo-tegra210.c:68-97`).

## 1. Rail

The proposed node is the Jetson TX1 / Nano node (`tegra210-p2180.dtsi:32-35`, `tegra210-p3450-0000.dts:1858-1870`): same PWM (`pwm` channel 1, period 8000 ns), same 710000–1320000 µV window, same MAX77620 GPIO 6 active-high enable, same ramp and settling. Darcy's stock rail is that circuit (`tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:110-123`): same PWM, same window, `enable-gpio = <&max77620 6 0>`.

Mainline continuous mode is what this node gets, because there is no `voltage-table` (`pwm-regulator.c:370-373`). With no `pwm-dutycycle-range`, the map is duty 0% → `regulator-min-microvolt` and duty 100% → `regulator-max-microvolt` (`pwm-regulator.c:301-319`, `213-225`). `regulator-n-voltages` is not read on that path. `desc.n_voltages` is set only from the length of `voltage-table` (`pwm-regulator.c:293`). Stock's `<62>` changes nothing under this driver.

The stock CPU OVR table is a different regulator (`&tegra_pwm_dfll`, `e2174-1101-a00.dtsi:86-107`). Its step 0 is 708000 µV and step 32 is 1322400 µV, which is the same direction as mainline's default (low duty, low voltage). It is not the GPU rail's map.

Two stock properties are absent from the proposal, and from the Jetson node: `regulator-init-microvolt = <1000000>` and the old `enable-gpio` spelling. The proposal's `enable-gpios` is the binding this driver uses (`pwm-regulator.c:392-397`). No `boot-on` / `always-on`, so GPIO 6 is driven output-low at probe and the rail stays off until a consumer enables it.

The downstream NVIDIA pwm-regulator that stock Android ran is not in this tree. I did not find a second implementation. Whether that driver treated `regulator-n-voltages` as an inverted step table is **UNCERTAIN**. Nothing in darcy's stock GPU node (no `voltage-table`, no `pwm-dutycycle-range`) asks for the inverted map. Polarity against the OVR pin has not been measured; the brief's INA3221 note stands. The software map matches Jetson TX1.

## 2. PWM pin

Putting the mux on `&pwm`'s `default` state is the right place.

- The driver core applies `default` before probe (`drivers/base/pinctrl.c:41-56`).
- Runtime resume applies it again (`pwm-tegra.c:379-385`).
- A missing `sleep` state is `ERR_PTR(-ENODEV)` (`drivers/pinctrl/core.c:1281-1288`, `drivers/base/pinctrl.c:72-76`). `pinctrl_select_bound_state` returns 0 for an error pointer (`core.c:1659-1660`), so runtime suspend does not switch the pin away (`pwm-tegra.c:370`).
- p2894's pinmux node only has a `boot` state (`tegra210-p2894.dtsi:26-27`). The core does not apply `boot`. The `pwm1` entry at `tegra210-p2894.dtsi:881-888` is inside `state_boot`, which is why `lcd_gpio2_pv4` is still DISPLAYB. The new state is referenced from `&pwm`, so it is applied. It is not a hog of the pinmux device.

The mux happens when `pwm-tegra` probes. At that moment channel 1's CSR is still 0 and the regulator has not run, so GPIO 6 is still an input reading low. A disabled Tegra PWM output is driven inactive (`pwm-tegra.c:27-28`). The rail's enable is GPIO 6, not the PWM pin (`e2174-1101-a00.dtsi:121`, proposal `enable-gpios`). The mux does not assert the enable. A short glitch on the OVR sense pin while enable is low is **UNCERTAIN** and does not turn the rail on.

The proposal omits `nvidia,open-drain`, which the boot-state node sets to disable (`tegra210-p2894.dtsi:887`). The live pinmux register is 0, so that bit is already clear. Unspecified pinmux properties are left untouched by the Tegra pinmux driver; this is not a functional gap.

## 3. `GPU_RG_CNTRL`

On Tegra210 `has_gpu_clamps` is true (`pmc.c:3864-3871`). The 3D partition is named in `tegra210_powergates[]` (`pmc.c:3720-3722`) and there is no `pd_3d` in `tegra210.dtsi`, so the legacy API keeps it (`pmc.c:2964-2967`). The GPU node has no `power-domains` (`tegra210.dtsi:440-457`), so nouveau takes the non-genpd path (`tegra.c:53-64`).

`tegra_pmc_powergate_remove_clamping(3D)` writes 0 to `GPU_RG_CNTRL` (`0x2d4`) through `tegra_pmc_writel` and returns 0 either way (`pmc.c:713-747`, `552-567`, `1102-1108`). A refused SMC is a warning. The function does not look at `res.a0`. I did not open this board's monitor or the upstream TF-A handler, so I will not put a probability on refusal. The same SMC write has already succeeded for other PMC offsets on this board. `0x2d4` has not been one of them.

If the clamp stays, power-up still returns success. The next GPU access is a raw `ioread32` of PRI `0x000004` / `0x000000` with no fault handler (`nvkm/engine/device/base.c:3123-3190`, `include/nvkm/core/device.h:127`). That is inside `nvkm_device_tegra_new` after `power_up` returns (`tegra.c:326-332`). This tree does not say whether a clamped aperture is a synchronous external abort, an SError, or a stuck AXI read. **UNCERTAIN.** Any of those happens in `modprobe`, before ACR or the volt table.

Read-only probe that does not touch the GPU aperture: `/sys/kernel/debug/powergate` (`pmc.c:3165`, `1228-1246`). For id 3D, `tegra_powergate_state` reads `GPU_RG_CNTRL` and treats bit 0 clear as powered (`pmc.c:590-593`, `1089-1094`). Do this before `modprobe nouveau` and look for `SMC failed`. `3d yes` means the clamp is already off. `3d no` means it is on, and the later write is still required. A warning on that read means the yes/no line is `res.a1` and is not evidence. `gm200_acr_wpr_check` is not a probe: it writes `0x100cd4` (`acr/gm200.c:53-61`).

## 4. Power-up order and the first touch

`gm20b` sets `require_vdd` and `require_ref_clk` (`nouveau_platform.c:66-69`).

Order in `nvkm_device_tegra_power_up` (`tegra.c:31-65`):

1. `regulator_enable(vdd)`.
2. Enable `gpu`, `ref`, and `pwr`. `pwr` is set to 204000000 Hz. `udelay(10)`.
3. Assert GPU reset. `udelay(10)`.
4. Remove 3D clamps (the SMC write above). `udelay(10)`.
5. Deassert reset. `udelay(10)`.

Then `nvkm_device_ctor` reads the GPU (`tegra.c:326-334`, `base.c:3190`). The volt subdev is constructed later and programs a voltage only from `gk20a_volt_vid_set` (`volt/gk20a.c:107-114`), which is after those reads. `gm20b_clk_init` also reads GPU registers before it raises the voltage (`clk/gm20b.c:811-860`).

Voltage at that first read:

- Both min and max are set, so `apply_uV` is true even without `regulator-init-microvolt` (`of_regulator.c:109-111`).
- A disabled PWM is reported as duty 0, which continuous mode maps to 710000 µV (`pwm-regulator.c:160-164`, `185-187`). The constraint pass sees a value already inside the window and does not call `set_voltage` (`core.c:1315-1367`).
- `pwm_adjust_config` stores period 8000 ns and duty 0 (`pwm/core.c:869-874`). `tegra_pwm_apply` returns without writing the CSR when the channel stays disabled (`pwm-tegra.c:249-253`). Channel 1 stays at CSR 0 through probe.
- `regulator_enable` drives GPIO 6 high, then `pwm_enable` (`pwm-regulator.c:115-121`, `include/linux/pwm.h:437-449`). The stored duty is 0, so the channel comes up at 0% → 710 mV. For the few writes between the GPIO and the CSR, a disabled output is driven inactive (`pwm-tegra.c:27-28`), the same level as 0% duty.

So the first MMIO is at 710 mV, below speedo 1's 840 mV floor (`volt/gm20b.c:61-64`). Nouveau will not ask for more than 1200000 µV (`volt/gk20a.c:114`) even though the regulator allows 1320000. The GPU clock is enabled at `clk_get_rate`, or `clk_set_rate(..., ULONG_MAX)` when that rate is 0, which the clock core clamps to the clock's maximum (`tegra.c:287-296`). I did not find a numeric maximum for `TEGRA210_CLK_GPU` in `clk-tegra210.c`. The `pwr` clock is 204 MHz.

This is the same node and the same `tegra.c` Jetson TX1 uses. Stock Android's 1000000 µV `regulator-init-microvolt` is the piece the proposal leaves out. The first-touch voltage matches mainline TX1, and it is lower than stock Android's init request.

## 5. Voltage and clock tables

No extra DT property. The tables are in the driver, indexed by `tegra_sku_info`, which the fuse driver fills. `tegra.c:330-331` copies `gpu_speedo_value` and `gpu_speedo_id`.

SKU `0x87` on A02 → `gpu_speedo_id` 1 (`speedo-tegra210.c:94-97`). That is inside `speedo_to_vmin[]` (five entries, ids 0–4). Id ≥ 5 is rejected (`volt/gm20b.c:74-77`). Id 1 uses `gm20b_na_cvb_coef` (through 998400 kHz) and vmin 840000 µV (`volt/gm20b.c:44-64`, `85-89`). The CVB coefficients are multiplied by `gpu_speedo_value` from `FUSE_CPU_SPEEDO_2` (`speedo-tegra210.c:152-159`, `volt/gk20a.c:80-89`). The fuse value itself was not read for this review. If it were ≤ 0, `tegra210_init_speedo_data` returns before assigning ids (`speedo-tegra210.c:171-176`) and the id stays 0, which selects the non-NA table. That is a fuse outcome, not a missing DT property.

Clock: speedo 0 takes `gm20b_clk_new_speedo0` (`clk/gm20b.c:1029-1030`). Speedo ≥ 1 reads `FUSE_RESERVED_CALIB0` (`clk/gm20b.c:946-977`). Fuse revision 0 logs `no fused calibration parameters` and continues (`clk/gm20b.c:959-1069`). `gm20b_clk_init` then writes the RAM SVOP override when fuse bits `[1:0]` of `0x021944` are clear (`clk/gm20b.c:837-846`). Clocks, reset, `vdd-supply`, and `iommus` are already on the SoC node (`tegra210.dtsi:447-454`). `TEGRA_IOMMU_SMMU=y` and `iommu_bit` 34 (`nouveau_platform.c:66-68`) are what that path requires.

## 6. LED

There is one clock for all four channels (`pwm-tegra.c:123-131`). It does not gate while any channel is enabled.

`tegra_pwm_enable` takes a runtime PM reference and leaves it (`pwm-tegra.c:211-218`). `tegra_pwm_disable` clears `PWM_ENABLE` and only then `pm_runtime_put_sync` (`pwm-tegra.c:228-237`). Channel 0 is the lightbar and its CSR is already enabled (`0x80ff00bb`), so the controller clock stays on while that LED is on. Channels 1–3 are not rewritten by a clock gate.

When the last channel does disable, the output is driven inactive first (`pwm-tegra.c:27-28`), and the clock gate follows. Runtime suspend's sleep pin state is a no-op here (question 2). What the pin does electrically once the controller clock stops, after the channel is already disabled, is **UNCERTAIN**. The gate does not reprogram channel 1 and it does not run while the lightbar holds channel 0.

## 7. WPR and the bootloader

GM20B does not allocate the WPR. `gm20b_acr_wpr_alloc` calls `wpr_check`, which writes 2 and then 3 to `0x100cd4` and reads the bounds (`acr/gm20b.c:33-45`, `acr/gm200.c:53-61`). If `end - start` is smaller than the image, the log line is `WPR image too big for WPR!` and the return is `-ENOSPC`. That runs only after PRI reads have already succeeded. A missing WPR is a failed `modprobe`, not a clamp problem.

The comment in `acr/base.c:286-291` says Tegra locates the WPR from those registers rather than allocating it. TX1's mainline DT has an empty `reserved-memory` node and no GPU `memory-region` (`tegra210-p2180.dtsi:21-25`). Nouveau's platform device reads `vdd`, `gpu`/`ref`/`pwr` clocks, the `gpu` reset, and the IOMMU (`tegra.c:267-320`). I found no `nvidia,` carveout property on that path. `gm20b_fb` has no VPR scrub (`fb/gm20b.c:26-35`).

Whether darcy's cboot programs `0x100cd4` the way Jetson cboot does is **UNCERTAIN**. Android's nvgpu programs the WPR itself when it loads, so a register left at zero by cboot is plausible. U-Boot in this tree has no WPR setup I could find by name. Firmware files the driver requests are `nvidia/gm20b/acr/bl.bin` and `acr/ucode_load.bin` (`acr/gm20b.c:91-94`), which the brief says are already on the rootfs. A zero WPR fails ACR after the GPU is up. It does not need a DT carveout to match TX1's mainline DTB. It does need the bootloader, or something before nouveau, to have written the bounds.

## 8. Userspace

Mesa's `tegra` gallium driver is the render-only wrapper: one screen on the tegra-drm device, rendering forwarded to nouveau, scanout buffers imported back. Mesa 26.0.3's meson still lists `tegra` in the aarch64 default set and errors if `tegra` is built without `nouveau`. I did not open the 26.2.5 tarball. The public Arch Linux ARM PKGBUILD snapshot is mesa 25.3.5 with `-D gallium-drivers=all`, which includes `tegra` on aarch64. The brief's repo package is 26.2.5, newer than that snapshot, so the exact configure line of the package that would be installed is **UNCERTAIN** until the package file list is checked. `gallium-drivers=all` on 26.0-era Mesa does ship `tegra`.

`eglinfo -p gbm` is the right check before any benchmark. The useful result is a GBM platform whose driver is `tegra` on the tegra-drm card. tegra-drm is already bound at boot, so it should enumerate ahead of nouveau. `glmark2-es2-drm` renders through GBM on the scanout device and is a sound first picture test once `eglinfo` shows that device. If it binds nouveau's node or llvmpipe, it is not exercising the split. kmscube is not in the repos; glmark2 is. pacman on the current kernel cannot install any of this until the Landlock build is what actually boots. That is independent of the GPU node.

## 9. Unrecoverable without the TV

HDMI-round recovery still holds for a kernel that is alive: a failed SMC is a log line, `RuntimeWatchdogSec` via `tegra_wdt` resets a kernel that stops petting it, `echo b` reboots rather than entering fastboot, and a power-pull does not enter fastboot. SSH over Wi-Fi is the way back when userspace is up.

Two new ways this step can go wrong:

1. Clamps left on, then the first `ioread32` of the GPU. `remove_clamping` has already returned 0, so nouveau does not abort first. If that read wedges the CPU or the interconnect, the 3-minute sysrq timer and the 60 s watchdog do not run. **UNCERTAIN** which fault the clamp actually produces. Power-pull is the recovery, and it does not land in fastboot. Read `/sys/kernel/debug/powergate` before `modprobe nouveau`. An `SMC failed` on that read is a reason to stop; the write nouveau is about to do would be ignored and the MMIO would follow.

2. The rail turns on inside `regulator_enable`, at 710 mV if the duty map is the Jetson one. If the OVR is inverted, 0% duty is the top of the 710–1320 mV window while the GPU is still in reset, and later CVB requests go the wrong direction. Destruction is **UNCERTAIN**. The enable GPIO is low until that call, so the dangerous moment is `modprobe`, not probe of the regulator. The sysrq timer does not undo a voltage that is already applied. SSH still works if the kernel survives. The `install nouveau /bin/true` line is what keeps a later boot from doing this by itself; the test has to pass `--ignore-install`.

`gm20b_acr_wpr_check` failing with `WPR image too big` is a returned `-ENOSPC` after MMIO works. It leaves the box on SSH.

## What I would do on the test boot

Expect, before `modprobe`: `pwm-tegra` bound, `lcd_gpio2_pv4` function PWM1, `vdd-gpu` registered, GPIO 6 output low, nouveau not loaded, channel 1 CSR still 0. Then `cat /sys/kernel/debug/powergate` and dmesg. Only then the 3-minute sysrq `b` timer and `modprobe --ignore-install nouveau`. Collect the regulator voltage (expect it to leave 710000 µV only once the volt subdev runs), channel 1 CSR, and whether `WPR image too big` appears. `eglinfo -p gbm` before `glmark2-es2-drm`.
