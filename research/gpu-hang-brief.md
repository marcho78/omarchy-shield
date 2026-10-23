# Short brief: why does the GM20B's first register read hang on darcy?

**Analysis only.** Do not change files or touch the device. Repository
`~/projects/nvidia` (`NOTES.md`), kernel `vendor/linux` (7.2.11). Cite
`file:line`; say plainly when something is a guess.

## Evidence (all measured on the SHIELD)

`tools/gpu-power-probe/gpu-power-probe.c` repeats nouveau's Tegra power-up
(`nvkm/engine/device/tegra.c`) one step at a time:
1. `regulator_enable(vdd-gpu)`. Optionally `regulator_set_voltage` first.
2. The gpu, ref (pll_g_ref) and pwr (pll_p_out5, set to 204 MHz) clocks.
3. Reset asserted.
4. `tegra_pmc_powergate_remove_clamping(3D)`.
5. Reset released.
6. `readl(BAR0 + 0x4)`.

Results:
- Steps 1–5 pass, and step 6 hangs the whole board. Recovery comes by the
  60 s hardware watchdog (about 2.5 min to fastboot, not a panic path). The
  same happens with the rail at 710 mV (0% duty) and at 1.0 V
  (`PWM_CSR_1` `0x807b0000`, regulator 1002800 µV).
- **The rail is real:** PMIC GPIO 6 reads `0x09` (output high) by direct
  I2C while the rail is on. The INA3221's VDD_SYS (18.9 V input) goes
  348 → 389 mA when the rail turns on (+0.77 W), and back to 349 mA after.
- **Held at step 5:**
  - CAR bank X bit 24 (gpu): clock enabled, reset deasserted
  - `GPU_RG_CNTRL` (PMC `0x2d4`, through the secure monitor) 0, so the
    clamps are off
  - MC hot reset `CTRL_1` (`0x970`) GPU bit 2 = 0, and `STATUS_1`
    (`0x974`) bit 2 went 1 → 0 when the GPU came up
- The SoC **fuse clock is gated** (clk_summary: `fuse` enable count 0,
  hardware enable N, consumer `7000f800.efuse`).

## NVIDIA's working sequence on Tegra210

nvgpu, L4T r32 kernel 4.9 (OE4T/linux-tegra-4.9,
`nvidia/nvgpu/drivers/gpu/nvgpu/os/linux/platform_gk20a_tegra.c`; a copy is
at
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/nvgpu-src/platform_gk20a_tegra.c`),
`gm20b_tegra_unrailgate()`. The clocks are `gpu_ref`, `pll_p_out5`, `emc`,
`fuse` (table at line 460) plus `gpu_gate`. The order:
1. Rail up.
2. Enable `gpu_gate`, `gpu_ref`, pwr, **and `fuse`** (`clk[3]`).
3. `udelay(10)`, reset assert, `udelay(10)`.
4. `GPU_RG_CNTRL` = 0, `udelay(10)`.
5. **`clk_disable(gpu_gate); reset_deassert; clk_enable(gpu_gate)`**.
6. **`tegra_mc_flush(MC_CLIENT_GPU)`, `udelay(10)`,
   `tegra_mc_flush_done(MC_CLIENT_GPU)`** ("Flush MC after
   boot/railgate/SC7").

Mainline nouveau does none of the three marked steps, and the mainline DT GPU
node has no fuse clock.

## Questions

1. Which of the three differences (fuse clock on, reset released with the
   gate clock off, MC flush/flush_done) is the likely reason a CPU read of
   BAR0 stalls? Is anything else in nvgpu's Tegra210 path (for example
   `tegra_soctherm_gpu_tsens_invalidate`, bwmgr or EMC) needed before the
   first PRI access?
2. How does mainline get away without the fuse clock on Jetson TX1 / Nano,
   if it does? Check `drivers/soc/tegra/fuse/fuse-tegra.c`'s clock and
   runtime-PM handling. Is the fuse clock left on there by something we
   don't have?
3. If nouveau needs one of these, what is the right mainline-shaped fix: a
   DT clock, a nouveau patch, or something else?

Write your answer as Markdown to
`/tmp/claude-1000/-home-marcho-projects-nvidia/ece463ed-6bb3-4ef0-bd2d-cd62f588f50f/scratchpad/review-gpu-hang-ncodex.md`
and reply with only that path.
