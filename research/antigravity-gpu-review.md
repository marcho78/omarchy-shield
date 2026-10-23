# GM20B (`nouveau`) Bring-Up Review on SHIELD TV 2017 (`darcy`)

## 1. Is the `vdd-gpu` rail right for `darcy`?

**Yes — the hardware rail, PWM channel, period, GPIO enable, and voltage range on `darcy` are identical to Jetson TX1 (`p2180`) and Jetson Nano (`p3450`), and mainline continuous mode produces the exact same PWM duty cycle as downstream.**

### Downstream `darcy` DT lineage
1. `vendor/lineage-t210-foster/kernel-dts/tegra210-darcy-p2894-0050-a08.dts:20` includes `foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi`.
2. `vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi:20` includes `t210-common-platforms/tegra210-ers-power-dvfs-e2174-1101-a00.dtsi` and does not override `gpu_ovr_reg` (`lines 198-213` only touch `cpu_ovr_reg`).
3. `vendor/lineage-t210-common/kernel-dts/t210-common-platforms/tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:110-123` defines:
   ```dts
   gpu_ovr_reg: pwm-regulator@1 {
       status = "okay";
       reg = <1>;
       compatible = "pwm-regulator";
       pwms = <&tegra_pwm 1 8000>;
       regulator-name = "vdd-gpu";
       regulator-min-microvolt = <710000>;
       regulator-max-microvolt = <1320000>;
       regulator-init-microvolt = <1000000>;
       regulator-n-voltages = <62>;
       regulator-enable-ramp-delay = <2000>;
       enable-gpio = <&max77620 6 0>;
       regulator-settling-time-us = <160>;
   };
   ```
4. Notice why downstream has `regulator-n-voltages = <62>`:
   - `1320000 - 710000 = 610000 µV`, and `610000 / 10000 + 1 = 62` steps (`0..61`) of **10 mV/step**.
   - In NVIDIA's downstream linear `pwm-regulator` driver, selector `0` is `0%` duty (`710 mV`) and selector `61` is `100%` duty (`1320 mV`) — normal polarity, linear mapping (`0% -> min_uV`, `100% -> max_uV`), matching the discrete table shown for `cpu_ovr_reg` right above it (`tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:86-108`, where `<0 708000>` is 0% duty and `<32 1322400>` is 100% duty).

### Mainline `pwm-regulator` continuous mode math
- Because your DT node omits `voltage-table`, `pwm_regulator_probe()` (`vendor/linux/drivers/regulator/pwm-regulator.c:370-373`) calls `pwm_regulator_init_continuous()` (`pwm-regulator.c:298-322`).
- `pwm_regulator_init_continuous()` defaults `drvdata->continuous.dutycycle_range = { 0, 100 }` and `dutycycle_unit = 100` (`pwm-regulator.c:291-294, 305-316`).
- Because `min_uV_dutycycle (0) < max_uV_dutycycle (100)`, `pwm_regulator_set_voltage()` (`pwm-regulator.c:190-236`) computes:
  $$\text{duty\_pct} = \text{DIV\_ROUND\_CLOSEST\_ULL}\left((\text{req\_min\_uV} - 710000) \times 100,\; 610000\right)$$
  and passes `(duty_pct, 100)` to `pwm_set_relative_duty_cycle()` (`vendor/linux/include/linux/pwm.h:255-266`), which converts it to nanoseconds out of `period = 8000 ns`.
- `tegra_pwm_config()` (`vendor/linux/drivers/pwm/pwm-tegra.c:108-111`) then converts `duty_ns / period_ns` into 256ths for `PWM_CSR_1[23:16]` (`PWM_DUTY_WIDTH = 8`).
- Both mainline Jetson TX1 (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2180.dtsi:426-436`) and mainline Jetson Nano (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts:1858-1871`) use this **exact** continuous-mode `pwm-regulator` node (`pwms = <&pwm 1 8000>`, `710000..1320000`, `enable-gpios = <&pmic 6 GPIO_ACTIVE_HIGH>`, `ramp-delay = <80>`, `enable-ramp-delay = <2000>`, `settling-time-us = <160>`).
- **Verdict:** No `pwm-dutycycle-range` or `pwm-dutycycle-unit` properties are needed; the defaults (`<0 100>` and `<100>`, normal polarity) match the OVR regulator hardware on `darcy`. (Adding `vin-supply = <&vdd_sys_boost>;` is optional tidy documentation since `vdd_sys_boost` is `regulator-always-on` at `tegra210-p2894.dtsi:1707-1717`).

---

## 2. The PWM pin (`lcd_gpio2_pv4`)

**Putting `pinctrl-0 = <&gpu_pwm_default>; pinctrl-names = "default";` on `&pwm` is the right place, and there is no glitch risk on the OVR regulator when the pin mux switches.**

1. **How `pwm-tegra` handles pinctrl:**
   - During device probe, the driver core (`really_probe()` -> `pinctrl_bind_pins()`) selects the `"default"` pinctrl state before `tegra_pwm_probe()` (`vendor/linux/drivers/pwm/pwm-tegra.c:280`) runs.
   - In addition, `tegra_pwm_runtime_resume()` (`pwm-tegra.c:379-396`) explicitly calls `pinctrl_pm_select_default_state(dev)` (`line 389`), and `tegra_pwm_runtime_suspend()` (`pwm-tegra.c:362-377`) calls `pinctrl_pm_select_sleep_state(dev)` (`line 367`), which is a no-op returning `0` when no `"sleep"` state is defined.
   - This is the exact pattern used by Jetson TX1 (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2180.dtsi:32-35`) and Jetson Nano (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts:112-115`).
2. **Why overriding `tegra210-p2894.dtsi`'s `rsvd1` pinmux will not glitch the rail:**
   - At boot (`5940c70` Dmesg in `NOTES.md:1066, 1219`), pin `lcd_gpio2_pv4` is `0x00000001` (`DISPLAYB`, driven low because `dc@54240000` is disabled) and PMIC GPIO 6 (`enable-gpios`) is input-low (`0x09`).
   - When `&pwm` probes, `lcd_gpio2_pv4` switches from `DISPLAYB` (low) to `PWM1` (low, since `PWM_CSR_1` bit 31 `ENB` is `0`), while PMIC GPIO 6 is still low (OVR controller disabled).
   - When `pwm_regulator_probe()` (`vendor/linux/drivers/regulator/pwm-regulator.c:395-403`) runs, it requests PMIC GPIO 6 with `GPIOD_OUT_LOW` (`line 395`) and calls `pwm_adjust_config(drvdata->pwm)` (`line 403`), which leaves the PWM channel disabled (`state.enabled = false`, `duty_cycle = 0` at `vendor/linux/drivers/pwm/core.c:869-874`).
   - Thus the OVR regulator's `EN` pin (PMIC GPIO 6) stays low the entire time the pinmux transitions.

---

## 3. `GPU_RG_CNTRL` (`0x2d4`) through the TZ secure monitor

1. **Does `__tegra_powergate_remove_clamping()` check if the write succeeded?**
   - **No.** In `vendor/linux/drivers/soc/tegra/pmc.c:724-729`:
     ```c
     if (id == TEGRA_POWERGATE_3D && pmc->soc->has_gpu_clamps) {
         tegra_pmc_writel(pmc, 0, GPU_RG_CNTRL);
         goto out;
     }
     ```
     and `out:` (`pmc.c:747`) unconditionally returns `0`.
   - Inside `tegra_pmc_writel()` (`pmc.c:559-571`), if the secure monitor rejects the SMC (`TEGRA_SMC_PMC = 0xc2fffe00`, `TEGRA_SMC_PMC_WRITE = 0xaa01`, offset `0x2d4`), `res.a0` is non-zero and `tegra_pmc_writel()` only prints a `WARN_ON_ONCE("%s(): SMC failed: %lu\n", __func__, res.a0)` (`line 569`).
   - Likewise, `tegra_pmc_readl()` (`pmc.c:538-551`) prints `WARN_ON_ONCE` if `res.a0 != 0` and still returns `(u32)res.a1`.

2. **What happens if the TZ secure monitor refuses `0x2d4` and leaves the clamp asserted?**
   - `GPU_RG_CNTRL` (`0x2d4`) bit 0 is the GPU rail-gating clamp (`0` = unclamped, `1` = clamped).
   - If `GPU_RG_CNTRL` remains `1` after `nvkm_device_tegra_power_up()` (`vendor/linux/drivers/gpu/drm/nouveau/nvkm/engine/device/tegra.c:35-65`) finishes, the GPU partition's outputs back to the SoC fabric remain clamped even though `PWRGATE_STATUS` bit 14 (`CRAIL`) and `CLK_OUT_ENB` / `RST_DEV` for GPU are enabled.
   - Immediately after `nvkm_device_tegra_power_up()` returns `0`, `nvkm_device_tegra_new()` calls `nvkm_device_ctor()` (`tegra.c:329`), which performs the first BAR0 MMIO read at `0x57000004` (`NV_PMC_BOOT_1`, `vendor/linux/drivers/gpu/drm/nouveau/nvkm/engine/device/base.c:3123`) and `0x57000000` (`NV_PMC_BOOT_0`, `base.c:3190`).
   - Depending on whether the internal host1x/AXI-to-GPU bridge gets a slave error / timeout or clamped `0` data when `GPU_RG_CNTRL=1`:
     - **Case A (clamped 0 data):** `nvkm_rd32(device, 0x000000)` returns `0x00000000`, `nvkm_device_ctor()` logs `nouveau 57000000.gpu: unknown chipset (00000000)` (`base.c:3366`) and fails cleanly with `-ENODEV`, calling `nvkm_device_tegra_power_down()` (`tegra.c:335-343`).
     - **Case B (AXI timeout / async SError):** The CPU takes an SError / synchronous external abort on the BAR0 read, panics (`panic_timeout=10`), and reboots cleanly into U-Boot.
   - *(Note on TOS handler likelihood — informed expectation, not verified from TOS binary)*: On Tegra210, the TZ PMC whitelist in standard NVIDIA TOS (`tos.img`) explicitly allows `GPU_RG_CNTRL` (`0x2d4`) because L4T/Android's own `nvgpu` driver unpowergates the GPU from non-secure EL1 via the exact same `TEGRA_SMC_PMC` (`0xc2fffe00`) call.

3. **Is there a safe read-only way to probe `0x2d4` first?**
   - You **cannot** use `devmem2 0x7000e6d4` from userspace because the PMC aperture (`0x7000e400`) is TZ-secured (`secure-pmc` in `NOTES.md:1079`); direct EL1 MMIO reads bypass the SMC path (`pmc.c:540-550`).
   - There is no sysfs/debugfs file in `drivers/soc/tegra/pmc.c` that exposes arbitrary PMC register reads.
   - However, because `tegra_pmc_writel()` has `WARN_ON_ONCE` on `res.a0 != 0` (`pmc.c:569`), if the SMC is rejected you will see `tegra_pmc_writel(): SMC failed: <err>` in `dmesg` before `nvkm_device_ctor()` touches BAR0. If you want a strictly read-only check before letting `nouveau` touch BAR0, a 5-line test module (or one-line `pr_info("GPU_RG_CNTRL=%x\n", tegra_pmc_readl(pmc, 0x2d4))` in `tegra_pmc_probe`) will invoke `TEGRA_SMC_PMC_READ` (`0xaa00`, `0x2d4`) and print both the SMC status (`WARN_ON_ONCE`) and the current `GPU_RG_CNTRL` value (`0x1` while clamped).

---

## 4. `nouveau`'s power-up order on GM20B — what voltage and clock is the GPU at when first touched?

Let's trace the exact call chain in `vendor/linux/drivers/gpu/drm/nouveau/` from module load through first MMIO and PLL lock:

### Step-by-step trace
1. **Before `nouveau` probes (`pwm-regulator` probe state):**
   - `pwm_regulator_probe()` (`vendor/linux/drivers/regulator/pwm-regulator.c:395-403`) sets PMIC GPIO 6 low (`GPIOD_OUT_LOW`) and calls `pwm_adjust_config(drvdata->pwm)`.
   - `pwm_adjust_config()` (`vendor/linux/drivers/pwm/core.c:869-874`) sees `state.period == 0`, so it initializes `state = { .period = 8000, .duty_cycle = 0, .polarity = PWM_POLARITY_NORMAL, .enabled = false }` and calls `pwm_apply_might_sleep()`.
   - In `tegra_pwm_apply()` (`vendor/linux/drivers/pwm/pwm-tegra.c:249-254`), because `!state->enabled && !enabled`, it returns `0` immediately without writing `PWM_CSR_1`.

2. **`nouveau_platform_probe()` -> `nvkm_device_tegra_new()` (`tegra.c:236-352`):**
   - `tegra.c:287-296`:
     ```c
     rate = clk_get_rate(tdev->clk);
     if (rate == 0) {
         ret = clk_set_rate(tdev->clk, ULONG_MAX);
         ...
     ```
     On Tegra210, `TEGRA210_CLK_GPU` is a gate clock parented to `pll_g_ref` (`38.4 MHz`), so `rate` is `38400000` (or even if `clk_set_rate(ULONG_MAX)` runs, `pll_g_ref` is fixed at 38.4 MHz until `nouveau`'s `clk` subdev programs `GPCPLL` via GPU MMIO).

3. **`nvkm_device_tegra_power_up(tdev)` (`tegra.c:35-65`):**
   - **Line 39:** `regulator_enable(tdev->vdd)`:
     - `_regulator_do_enable()` (`vendor/linux/drivers/regulator/core.c:3018-3061`) calls `pwm_regulator_enable()` (`pwm-regulator.c:115-122`) and then `fsleep(2000)` (`regulator-enable-ramp-delay = <2000>`).
     - `pwm_regulator_enable()` sets PMIC GPIO 6 **HIGH** and calls `pwm_enable(drvdata->pwm)` (`include/linux/pwm.h:132-142`), which applies `state = { .period = 8000, .duty_cycle = 0, .enabled = true }`.
     - `tegra_pwm_apply()` (`pwm-tegra.c:256-262`) programs `PWM_CSR_1` with **0% duty cycle** (`duty = 0`, `ENB = 1`).
     - Therefore, when `regulator_enable(tdev->vdd)` returns after the 2 ms ramp delay, **`vdd_gpu` is physically at `710 mV` (`regulator-min-microvolt`)**!
   - **Lines 43-51:** Enables `clk` (`gpu`), `clk_ref` (`pll_g_ref` = 38.4 MHz), and `clk_pwr` (`pll_p_out5` = 204 MHz). At this point `GPCPLL` inside the GPU is powered down (`IDDQ=1`) and in bypass, so the GPU logic is clocked only by the low-speed reference/power clocks (`38.4 MHz` / `204 MHz`).
   - **Lines 53-65:** Calls `tegra_powergate_remove_clamping(TEGRA_POWERGATE_3D)`, waits 10 us, deasserts `tdev->rst`, and waits 10 us.

4. **`nvkm_device_ctor()` (`base.c:3083-3448`):**
   - Reads `NV_PMC_BOOT_1` (`0x000004`) and `NV_PMC_BOOT_0` (`0x000000`) (`base.c:3123, 3190`) — **at `710 mV` and bypass clock (`38.4 MHz`)**.
   - Runs all subdev constructors (`gm20b_volt_new`, `gm20b_clk_new`, etc.). Neither `gm20b_volt_new()` (`volt/gm20b.c:71-92`) nor `gm20b_clk_new()` (`clk/gm20b.c:993-1064`) changes the regulator voltage or locks `GPCPLL`.

5. **`nvkm_device_init()` (`base.c:3038-3072`) — subdev init order (`include/nvkm/core/layout.h:23-28`):**
   - Subdevs initialize in `layout.h` order: `ACR` (line 23) -> `PMU` (line 24) -> `VOLT` (line 25) -> `THERM` (line 27) -> `CLK` (line 28) -> engines (`FIFO`, `GR`).
   - **Subtle quirk in `VOLT` + `CLK` init on GM20B:**
     1. When `VOLT` initializes (`nvkm_volt_init()` at `volt/base.c:224-235`), `volt->func->init` is `NULL`, so `nvkm_volt_init()` is a no-op.
     2. When `CLK` initializes (`nvkm_clk_init()` at `clk/base.c:595-626`), look at lines 617-624:
        ```c
        if (clk->func->init)
            return clk->func->init(clk);

        return nvkm_pstate_calc(clk, true);
        ```
        Because `gm20b_clk` (and `gm20b_clk_speedo0`) sets `.init = gm20b_clk_init` (`clk/gm20b.c:955, 987`), `nvkm_clk_init()` returns `gm20b_clk_init(clk)` directly at line 618 and **skips `nvkm_pstate_calc(clk, true)`**!
     3. Inside `gm20b_clk_init()` (`clk/gm20b.c:812-878`):
        - It calls `_clk->uv = nvkm_volt_get(volt)` (`line 852`).
        - `nvkm_volt_get()` (`volt/base.c:32-48`) calls `gk20a_volt_vid_get()` (`volt/gk20a.c:93-105`), which reads `uv = regulator_get_voltage(volt->vdd)` (`710000 µV`) and returns the first `vid[i]` with `vid[i].uv >= 710000`, which is `i = 0` (`840000 µV` on SKU `0x87` speedo 1, or `950000 µV` on speedo 0)!
        - `gm20b_clk_init()` then runs `gm20b_clk_init_dvfs()` (`line 853`) and locks `GPCPLL` to `pstates[0]` (`76.8 MHz` GPC / `153.6 MHz` GPC2CLK, `lines 860-866`) **while `vdd_gpu` is still physically at `710 mV` (`0%` duty)**!
        - Finally `gm20b_clk_init()` calls `gk20a_devfreq_init()` (`line 871`, `clk/gk20a_devfreq.c:261-300`), which starts devfreq polling (`50 ms` interval, `gk20a_devfreq.c:241`). When devfreq's first poll fires (or if a pstate is requested), `gk20a_devfreq_target()` -> `nvkm_clk_ustate()` -> `nvkm_pstate_calc()` -> `nvkm_cstate_prog()` (`clk/base.c:187`) calls `nvkm_volt_set_id()`, which calls `regulator_set_voltage()` to raise `vdd_gpu` into the `vmin..vmax` range (`840..1045 mV`).

### Is `710 mV` at 38.4 MHz / 76.8 MHz (`pstates[0]`) safe on GM20B?
- **Yes:**
  1. This is the **exact** code path that runs on mainline Jetson TX1 (`tegra210-p2180.dtsi:426-436`) and Jetson Nano (`tegra210-p3450-0000.dts:1858-1871`), both of which have `regulator-min-microvolt = <710000>` and no initial voltage override.
  2. In downstream (`tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:110-123`), `710 mV` is the hardware minimum output of the OVR regulator (`0%` PWM duty) and is well above SRAM/logic retention for GM20B at 38.4 MHz bypass / 76.8 MHz `pstates[0]`.
  3. *(Optional belt-and-suspenders tip)*: If you ever wanted `vdd_gpu` to start at `>= 840 mV` (`vmin`) even before devfreq's first tick, raising `regulator-min-microvolt` in `darcy.dts` or setting `nouveau`'s `NvBoost` / pstate after load isn't even needed unless `gm20b_clk_init_dvfs` shows any instability, because `gm20b_clk_init` only switches to `pstates[0]` (`76.8 MHz`).

---

## 5. Speedo / fuse dependency (`gm20b_volt_new` & `gm20b_clk_new`)

**Both `tegra_sku_info` (`gpu_speedo_id`, `gpu_speedo_value`) and `tegra_fuse_readl(FUSE_RESERVED_CALIB0)` are already populated and working on `darcy`.**

1. **`tegra_sku_info.gpu_speedo_id` and `tegra_sku_info.gpu_speedo_value`:**
   - Populated at `early_initcall(tegra_init_fuse)` (`vendor/linux/drivers/soc/tegra/fuse/fuse-tegra.c:470-570`), which calls `fuse->soc->init(fuse)` (`tegra210_fuse_init` -> `tegra210_init_speedo_data()` in `vendor/linux/drivers/soc/tegra/fuse/speedo-tegra210.c:115-194`).
   - Your boot log in `NOTES.md:1078` already confirms `tegra_init_fuse()` ran and read the fuses:
     `Tegra Revision: A02 SKU: 135 CPU Process: 0 SoC Process: 0` (`SKU 135 = 0x87`).
   - In `speedo-tegra210.c:62-84` (`get_sku_id()`), `case 0x87:` (with revision `!= TEGRA_REVISION_A01`, since `darcy` is `A02`) sets `sku_info->gpu_speedo_id = 1` (`line 67`).
   - In `speedo-tegra210.c:150-189`, `gpu_speedo_value` is read from `FUSE_GPU_INFO` (`offset 0x1c0`, `line 150`) and multiplied by `4` (`line 161`). Because `gpu_speedo_value > 0` on real silicon, `gm20b_volt_new()` (`volt/gm20b.c:71-92`) will succeed and select `gm20b_na_volt_10` (`vmin = 840000 µV`, `vmax = 1045000 µV`, `volt/gm20b.c:42-67`), and `gm20b_clk_new()` (`clk/gm20b.c:993-1025`) will select the full `gm20b_clk` DVFS table (`76.8 MHz .. 921.6 MHz`, `clk/gm20b.c:901-958`).

2. **`tegra_fuse_readl(FUSE_RESERVED_CALIB0, &calib)` (`clk/gm20b.c:92-125`):**
   - `fuse@7000f800` in `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:1003-1010` has no `status = "disabled"` property, so it is **enabled by default**.
   - The `tegra-fuse` platform driver (`fuse-tegra.c:319-329`) is built-in (`builtin_platform_driver(tegra_fuse_driver)`), probes at boot (`tegra_fuse_probe`, `fuse-tegra.c:139-257`), and sets `fuse->dev`, `fuse->clk`, and `fuse->read`.
   - Therefore, when `gm20b_clk_new()` -> `gm20b_dvfs_calc_det_coeff()` (`clk/gm20b.c:92-125`) calls `tegra_fuse_readl(FUSE_RESERVED_CALIB0, &calib)` (`fuse-tegra.c:343-363`), it returns `0` immediately (no `-EPROBE_DEFER` or error).

---

## 6. Shared PWM controller (`pwm@7000a000`)

**Confirmed: `pwm@7000a000` has no other consumers in mainline `darcy.dts` / `tegra210-p2894.dtsi`, and even if `cboot` left the green LED on via PWM0, `pwm-tegra`'s clock gating is safe.**

1. **No other mainline DT consumers:**
   - In `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:695-703`, `pwm: pwm@7000a000` is `status = "disabled"`.
   - Neither `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi` nor `kernel/dts/darcy.dts` references `&pwm` anywhere today (`leds-pwm` is not in the mainline DT).
   - Downstream (`vendor/lineage-t210-foster/kernel-dts/foster-platforms/tegra210-foster-led.dtsi` / `darcy`) uses an I2C/MCU LED controller on SHIELD TV (not `leds-pwm`), and fan control on `darcy` is not bound to `&pwm` in `darcy.dts`.

2. **What happens to PWM channel 0 when `pwm-tegra` probes and suspends?**
   - In `tegra_pwm_probe()` (`vendor/linux/drivers/pwm/pwm-tegra.c:280-346`), after `devm_pwmchip_add()` (`line 331`), `pm_runtime_put(&pdev->dev)` (`line 337`) triggers `tegra_pwm_runtime_suspend()` (`pwm-tegra.c:362-377`), which calls `clk_disable_unprepare(pc->clk)` (`TEGRA210_CLK_PWM`).
   - When `nouveau` enables `vdd_gpu`, `pwm_enable()` -> `tegra_pwm_apply()` (`pwm-tegra.c:210`) calls `pm_runtime_resume_and_get()` (enabling `TEGRA210_CLK_PWM`), writes only channel 1 (`PWM_CSR_1` at offset `0x10`, because `pwm_writel(pc, pwm->hwpwm, ...)` indexes `num << 4` at `pwm-tegra.c:66-69`), and then calls `pm_runtime_put()` **only when channel 1 is disabled** (`pwm-tegra.c:251, 267`). While `vdd_gpu` is enabled, `pm_runtime_Resume_and_get()` holds a runtime PM reference (`pwm-tegra.c:259` does **not** call `pm_runtime_put()` when `!enabled && state->enabled`!).
   - Thus channel 0's register (`PWM_CSR_0` at offset `0x00`) is never touched by channel 1 operations, and `TEGRA210_CLK_PWM` remains enabled whenever `vdd_gpu` is enabled.

---

## 7. Memory / IOMMU / WPR interaction

Let's check every memory/IOMMU/WPR path `nouveau` takes on GM20B (`tegra210.dtsi:490-519`):

1. **Tegra SMMU (`iommus = <&mc TEGRA_SWGROUP_GPU>` at `tegra210.dtsi:516`):**
   - In `nvkm_device_tegra_probe_iommu()` (`vendor/linux/drivers/gpu/drm/nouveau/nvkm/engine/device/tegra.c:116-195`), `nouveau` detaches the GPU from the default DMA-IOMMU domain (`iommu_detach_device`) and attaches its own `IOMMU_DOMAIN_UNMANAGED` domain (`iommu_domain_alloc(&platform_bus_type)`), setting up an internal `nvkm_mm` over the SMMU aperture (`bit 34` = `tdev->func->iommu_bit = 34` at `nouveau_platform.c:64`).
   - `gk20a_instmem_new()` (`vendor/linux/drivers/gpu/drm/nouveau/nvkm/subdev/instmem/gk20a.c:591-598`) and `gm20b_mmu` use this SMMU domain to map GPU buffers (`instmem` and `vmm`).
   - Note: `gpu@57000000` is a pure renderer (no scanout engine), so there is no bootloader framebuffer scanout running from `TEGRA_SWGROUP_GPU` at boot — attaching `TEGRA_SWGROUP_GPU` to `tdev->iommu.domain` will not fault MC like `dc@54200000` did when `cboot` left DC scanning out.

2. **WPR (Write-Protected Region) carveout (`acr/gm20b.c` & `acr/gm200.c`):**
   - **How GM20B locates WPR:** Unlike dGPUs (which allocate WPR themselves), on Tegra210 the Memory Controller's WPR1 security carveout (`MC_SECURITY_CARVEOUT2_*`) is configured by the bootloader (`nvtboot` / TrustZone / `cboot`) and broadcast by the MC to the GPU's MMU register `NV_PFB_PRI_MMU_WPR_INFO` (`0x100cd4`).
   - During `nvkm_acr_oneinit()` (`vendor/linux/drivers/gpu/drm/nouveau/nvkm/subdev/acr/base.c:292`), `gm20b_acr_wpr_alloc()` (`acr/gm20b.c:36-50`) calls `gm200_acr_wpr_check()` (`acr/gm200.c:53-62`), which reads `wpr_start` (`index 2` of `0x100cd4`) and `wpr_end` (`index 3` of `0x100cd4` + `0x20000`).
   - **What if `cboot` did NOT lock a WPR carveout, or configured size 0?**
     - Look at `gm20b_acr_wpr_alloc()` (`acr/gm20b.c:41-49`):
       ```c
       acr->func->wpr_check(acr, &acr->wpr_start, &acr->wpr_end);

       if ((acr->wpr_end - acr->wpr_start) < wpr_size) {
           nvkm_error(&acr->subdev, "WPR image too big for WPR!\n");
           return -ENOSPC;
       }
       return nvkm_memory_new(acr->subdev.device, NVKM_MEM_TARGET_INST,
                              wpr_size, 0x40000, true, &acr->wpr);
       ```
     - First, if `wpr_end - wpr_start < wpr_size`, it fails **gracefully** with `-ENOSPC` (`"WPR image too big for WPR!"`) and powers down the GPU — no hang or crash.
     - Second, notice how `gm20b_acr_wpr_alloc()` allocates `acr->wpr`: it allocates normal `NVKM_MEM_TARGET_INST` memory (`nvkm_memory_new`) for the shadow blob that the CPU writes (`acr/base.c:300-321`), and then the signed ACR HS `load` firmware (`nvidia/gm20b/acr/ucode_load.bin`, booted on the PMU Falcon in HS mode at `acr/gm200.c:47-50` -> `acr/gm20b.c:79-83`) DMA-copies the image into the physical WPR carveout and verifies `wpr_check()` (`acr/base.c:105-112`).
     - On SHIELD TV (`darcy`), `nvtboot` / `cboot` sets up the standard Tegra210 WPR carveout before booting the kernel (because downstream Android `nvgpu` requires the exact same WPR carveout and signed `gm20b/acr` HS loader).

3. **Flush benchmark page (`fb/gm20b.c` & `fb/gm200.c`):**
   - `gm20b_fb_init()` (`fb/gm20b.c:26-34`) programs `device->func->resource_addr(device, 1)` (`0x100c80`) using the `fb->sysmem.flush_page_init` page allocated via `dma_alloc_coherent()` in `gm200_fb_oneinit()` (`fb/gm200.c:42-53`). This uses standard coherent DMA and has no special carveout dependency.

---

## 8. Firmware file list verification

Let's check every `NVKM_ACR_HSF_BUILD` / `NVKM_ACR_LSF_BUILD` / `nvkm_firmware_get` call executed on GM20B (`chipset = 0x12b`):

| Subdev / Engine | Source (`file:line`) | `ver` | Firmware paths requested (`nvidia/gm20b/...`) | Present in your list? |
|---|---|---|---|---|
| `acr` (HS load) | `nvkm/subdev/acr/gm20b.c:89-99` (`gm20b_acr_load_fwif`, `ver=0`) | `0` | `acr/bl.bin`, `acr/ucode_load.bin` | **Yes** |
| `pmu` (LSF) | `nvkm/subdev/pmu/gm20b.c:117-122` (`gm20b_pmu_fwif`, `ver=0`) | `0` | `pmu/desc.bin`, `pmu/image.bin`, `pmu/sig.bin` | **Yes** |
| `gr` / FECS (LSF) | `nvkm/engine/gr/gm20b.c:99-105` (`gm20b_flcn_fwif`, `ver=0`) | `0` | `gr/fecs_bl.bin`, `gr/fecs_inst.bin`, `gr/fecs_data.bin`, `gr/fecs_sig.bin` | **Yes** |
| `gr` / GPCCS (LSF) | `nvkm/engine/gr/gm20b.c:119-125` (`gm20b_gpccs_fwif`, `ver=0`) | `0` | `gr/gpccs_bl.bin`, `gr/gpccs_inst.bin`, `gr/gpccs_data.bin`, `gr/gpccs_sig.bin` | **Yes** |
| `gr` bundle/ctx | `nvkm/engine/gr/gm20b.c:128-134` -> `gk20a_gr_load_sw` (`gr/gk20a.c:267-302`) | `0` | `gr/sw_ctx.bin`, `gr/sw_nonctx.bin`, `gr/sw_bundle_init.bin`, `gr/sw_method_init.bin` | **Yes** |

- **What about `gm200_gr_nofw` / netlist (`fecs_inst`, `fecs_data`, `gpccs_inst`, `gpccs_data`)?**
  - `gm20b_gr_fwif` (`gr/gm20b.c:127-136`) only has `{ 0, gm20b_gr_load, &gm20b_gr }` (`load = true` for both FECS and GPCCS in `gm20b_gr_flcn_fwif` and `gm20b_gr_gpccs_fwif`, `lines 101, 121`), which calls `gf100_gr_fecs_load_ctxsw()` (`gr/gf100.c`) to load `fecs_inst.bin` / `fecs_data.bin` / `gpccs_inst.bin` / `gpccs_data.bin` directly via `nvkm_firmware_get()`.
- **What about `acr/ucode_unload.bin`?**
  - `gm20b_acr_fwif` (`acr/gm20b.c:102-106`) only defines `load` (`gm20b_acr_load_fwif`); it does **not** define an `unload` HS firmware on GM20B (`acr/gm20b.c:85-99`).
- **Conclusion:** Your 16-file `/lib/firmware/nvidia/gm20b/{acr,gr,pmu}/` list is **100% complete** for GM20B.

---

## 9. Verdict: Go / No-Go and Failure Modes

### Verdict: **GO** (with `nouveau` kept as a manual/non-autoload module or blacklisted until tested via `modprobe nouveau` over SSH)

The proposed DT additions in `kernel/dts/darcy.dts` (`gpu_pwm_default` on `lcd_gpio2_pv4`, `&pwm` enabled, `vdd_gpu: regulator-vdd-gpu`, and `gpu@57000000` with `vdd-supply = <&vdd_gpu>` and `status = "okay"`) match both the downstream `darcy` power tree (`tegra210-ers-power-dvfs-e2174-1101-a00.dtsi:110-123`) and mainline Jetson TX1 (`tegra210-p2180.dtsi:32-35, 426-436`) / Jetson Nano (`tegra210-p3450-0000.dts:112-115, 1858-1871`).

### Ranked Failure Modes & How Each Manifests

1. **Rank 1 (Most likely, non-fatal): WPR carveout mismatch (`-ENOSPC` or `-EIO` in `acr`)**
   - **Cause:** `cboot` on `darcy` either left `MC_SECURITY_CARVEOUT2` (`WPR1`) unconfigured (`0x100cd4` reads `0`), or configured it differently from what `gm20b/acr/ucode_load.bin` expects.
   - **Manifestation:** Clean probe failure (`-ENOSPC` `"WPR image too big for WPR!"` at `acr/gm20b.c:45`, or `-EIO` `"WPR not configured as expected"` at `acr/base.c:108`), followed by `nouveau` cleanly powering down the GPU (`tegra.c:335-343`). SSH stays up; no crash or reboot.

2. **Rank 2 (Possible, non-fatal or soft error): `gm20b_clk_init()` / `gm20b_clk_init_dvfs()` running at `710 mV` before devfreq's first voltage step**
   - **Cause:** As traced in Question 4, `pwm-regulator` starts at `0%` duty (`710 mV`) on `regulator_enable()`, and `gm20b_clk_init()` (`clk/gm20b.c:812-878`) calibrates DFS and locks `GPCPLL` at `pstates[0]` (`76.8 MHz`) before `gk20a_devfreq` calls `nvkm_volt_set_id()` to raise `vdd_gpu` to `vmin` (`840 mV`).
   - **Manifestation:** Works fine on TX1/Nano at `76.8 MHz`, but if `darcy` silicon or `gm20b_clk_init_dvfs()` needs `>= 840 mV` during PLL/ADC calibration, `gm20b_pll_lock()` (`clk/gm20b.c:316`) times out after 300 us with `"PLL lock timeout"` (`-ETIMEDOUT`, clean probe failure).
   - **Easy fix if seen:** Set `regulator-min-microvolt = <840000>` (or call `nvkm_volt_set_id` in `gm20b_clk_init` before `gm20b_clk_init_dvfs`), keeping the `710..1320 mV` slope via a 2-entry or continuous range if needed, or patch `gm20b_clk_init()` to set `volt->min_id` first.

3. **Rank 3 (Low likelihood, fatal/reboot): TZ secure monitor rejects `GPU_RG_CNTRL` (`0x2d4`) or BAR0 access faults**
   - **Cause:** `tegra_pmc_writel(pmc, 0, GPU_RG_CNTRL)` (`pmc.c:725`) fails in TZ (`res.a0 != 0`), leaving the GPU partition clamped when `nvkm_device_ctor()` reads `0x57000004` (`base.c:3123`).
   - **Manifestation:** First prints `WARNING: ... tegra_pmc_writel(): SMC failed: ...` in `dmesg`, followed immediately by either `"unknown chipset (00000000)"` (clean `-ENODEV` failure) or an SError / synchronous external abort -> kernel panic -> 10-second `panic_timeout` reboot back into U-Boot.
