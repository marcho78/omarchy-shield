// SPDX-License-Identifier: GPL-2.0
/*
 * Powers the GM20B up as nouveau does (nvkm_device_tegra_new() and
 * nvkm_device_tegra_power_up() in drivers/gpu/drm/nouveau/nvkm/engine/
 * device/tegra.c), one step at a time. It logs before and after each step
 * and pauses between steps, so that a step which hangs the board shows in a
 * streamed kernel log. It binds the GPU node in nouveau's place (nouveau
 * must not be loaded) and holds the GPU up until it is removed, which
 * undoes the steps. It has no module alias, so nothing loads it by itself.
 *
 *   insmod gpu-power-probe.ko steps=6 pause_ms=3000 [uv=1000000]
 *                              [fuse=1] [gate_reset=1] [mc_flush=1]
 *
 * uv sets the rail's voltage before step 1 turns it on; without it the rail
 * starts where the regulator stands, at its floor (nouveau's case). The
 * other switches add what NVIDIA's nvgpu does on Tegra210 and nouveau
 * doesn't (gm20b_tegra_unrailgate() in nvgpu's platform_gk20a_tegra.c):
 *   fuse        the SoC fuse clock on with the others (nvgpu's clk[3])
 *   gate_reset  the reset released with the gpu clock stopped
 *   mc_flush    the GPU's memory-controller client flushed and released
 *               after the reset (tegra_mc_flush(), tegra_mc_flush_done())
 *
 * Steps: 1 the rail on, 2 the clocks, 3 the reset asserted, 4 the clamps
 * removed, 5 the reset released, 6 the first register reads (BOOT_1,
 * BOOT_0). nouveau's IOMMU attach, before the power-up, is left out:
 * register reads from the CPU don't go through the IOMMU.
 *
 * Build: tools/build-module.sh gpu-power-probe
 */
#include <linux/arm-smccc.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regulator/consumer.h>
#include <linux/reset.h>
#include <soc/tegra/pmc.h>
#include <dt-bindings/clock/tegra210-car.h>

#define TEGRA_SMC_PMC		0xc2fffe00
#define TEGRA_SMC_PMC_READ	0xaa
#define TEGRA_SMC_PMC_WRITE	0xbb
#define GPU_RG_CNTRL		0x2d4

/* The clock and reset controller's bits for the PWM block, and its channel 1 */
#define CAR_BASE		0x60006000
#define CAR_RST_DEVICES_L	0x004
#define CAR_CLK_OUT_ENB_L	0x010
#define CAR_PWM_BIT		BIT(17)
#define PWM_BASE		0x7000a000
#define PWM_CSR_1		0x10

/* The memory controller's hot reset of the GPU client (drivers/memory/tegra/tegra210.c) */
#define MC_BASE			0x70019000
#define MC_HOTRESET_CTRL_1	0x970
#define MC_HOTRESET_STATUS_1	0x974
#define MC_HOTRESET_GPU		BIT(2)

static int steps = 6;
module_param(steps, int, 0444);
MODULE_PARM_DESC(steps, "How many power-up steps to take (0-6)");

static int pause_ms = 3000;
module_param(pause_ms, int, 0444);
MODULE_PARM_DESC(pause_ms, "Pause around each step, so that its log line gets out");

static int uv;
module_param(uv, int, 0444);
MODULE_PARM_DESC(uv, "Rail voltage to set before turning it on, in uV (0: leave it)");

static bool fuse;
module_param(fuse, bool, 0444);
MODULE_PARM_DESC(fuse, "Also turn the SoC fuse clock on, as nvgpu does");

static bool gate_reset;
module_param(gate_reset, bool, 0444);
MODULE_PARM_DESC(gate_reset, "Release the reset with the gpu clock stopped, as nvgpu does");

static bool mc_flush;
module_param(mc_flush, bool, 0444);
MODULE_PARM_DESC(mc_flush, "Flush and release the GPU's MC client after the reset, as nvgpu does");

struct gpu_probe {
	void __iomem *regs;
	struct regulator *vdd;
	struct clk *clk, *clk_ref, *clk_pwr, *clk_fuse;
	struct reset_control *rst;
	struct tegra_pmc *pmc;
	int done;
};

/* GPU_RG_CNTRL through the secure monitor, as tegra_pmc_readl()/writel() reach it */
static u32 gpu_rg_cntrl(void)
{
	struct arm_smccc_res res;

	arm_smccc_smc(TEGRA_SMC_PMC, TEGRA_SMC_PMC_READ, GPU_RG_CNTRL,
		      0, 0, 0, 0, 0, &res);
	return res.a0 ? ~0u : res.a1;
}

static void set_gpu_rg_cntrl(u32 value)
{
	struct arm_smccc_res res;

	arm_smccc_smc(TEGRA_SMC_PMC, TEGRA_SMC_PMC_WRITE, GPU_RG_CNTRL,
		      value, 0, 0, 0, 0, &res);
}

/* PWM channel 1's CSR, read only while the block is clocked and out of reset */
static void show_pwm(struct device *dev)
{
	void __iomem *car = ioremap(CAR_BASE, 0x100);
	void __iomem *pwm;
	u32 clk, rst;

	if (!car)
		return;
	clk = readl(car + CAR_CLK_OUT_ENB_L);
	rst = readl(car + CAR_RST_DEVICES_L);
	iounmap(car);
	if (!(clk & CAR_PWM_BIT) || (rst & CAR_PWM_BIT)) {
		dev_info(dev, "  PWM block not clocked or in reset: CSR not read\n");
		return;
	}
	pwm = ioremap(PWM_BASE, 0x100);
	if (!pwm)
		return;
	dev_info(dev, "  PWM_CSR_1 %#010x\n", readl(pwm + PWM_CSR_1));
	iounmap(pwm);
}

/* tegra_mc_flush() then tegra_mc_flush_done() for the GPU client */
static void flush_mc(struct device *dev)
{
	void __iomem *mc = ioremap(MC_BASE, 0x1000);
	u32 status = 0;
	int i;

	if (!mc)
		return;
	writel(readl(mc + MC_HOTRESET_CTRL_1) | MC_HOTRESET_GPU, mc + MC_HOTRESET_CTRL_1);
	for (i = 0; i < 1000; i++) {
		status = readl(mc + MC_HOTRESET_STATUS_1);
		if (status & MC_HOTRESET_GPU)
			break;
		udelay(1);
	}
	udelay(10);
	writel(readl(mc + MC_HOTRESET_CTRL_1) & ~MC_HOTRESET_GPU, mc + MC_HOTRESET_CTRL_1);
	udelay(10);
	dev_info(dev, "  MC flush: status %#x after %d us, released: ctrl %#x status %#x\n",
		 status, i, readl(mc + MC_HOTRESET_CTRL_1), readl(mc + MC_HOTRESET_STATUS_1));
	iounmap(mc);
}

static void step_pause(void)
{
	msleep(pause_ms);
}

static int gpu_probe_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct gpu_probe *gp;
	int err;
	u32 boot0, boot1;

	gp = devm_kzalloc(dev, sizeof(*gp), GFP_KERNEL);
	if (!gp)
		return -ENOMEM;
	platform_set_drvdata(pdev, gp);

	gp->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(gp->regs))
		return PTR_ERR(gp->regs);
	gp->vdd = devm_regulator_get(dev, "vdd");
	if (IS_ERR(gp->vdd))
		return dev_err_probe(dev, PTR_ERR(gp->vdd), "no vdd\n");
	gp->rst = devm_reset_control_get(dev, "gpu");
	if (IS_ERR(gp->rst))
		return dev_err_probe(dev, PTR_ERR(gp->rst), "no gpu reset\n");
	gp->clk = devm_clk_get(dev, "gpu");
	if (IS_ERR(gp->clk))
		return dev_err_probe(dev, PTR_ERR(gp->clk), "no gpu clock\n");
	gp->clk_ref = devm_clk_get(dev, "ref");
	if (IS_ERR(gp->clk_ref))
		return dev_err_probe(dev, PTR_ERR(gp->clk_ref), "no ref clock\n");
	gp->clk_pwr = devm_clk_get(dev, "pwr");
	if (IS_ERR(gp->clk_pwr))
		return dev_err_probe(dev, PTR_ERR(gp->clk_pwr), "no pwr clock\n");
	gp->pmc = devm_tegra_pmc_get(dev);
	if (IS_ERR(gp->pmc))
		return dev_err_probe(dev, PTR_ERR(gp->pmc), "no PMC\n");
	if (fuse) {
		struct of_phandle_args spec = { .args_count = 1, .args = { TEGRA210_CLK_FUSE } };

		/* The GPU node names no fuse clock; take it from the clock controller */
		spec.np = of_find_compatible_node(NULL, NULL, "nvidia,tegra210-car");
		gp->clk_fuse = of_clk_get_from_provider(&spec);
		of_node_put(spec.np);
		if (IS_ERR(gp->clk_fuse))
			return dev_err_probe(dev, PTR_ERR(gp->clk_fuse), "no fuse clock\n");
	}

	/* As nouveau: a gpu clock that reads 0 is set to its maximum */
	if (!clk_get_rate(gp->clk))
		clk_set_rate(gp->clk, ULONG_MAX);

	dev_info(dev, "start: vdd %s at %d uV, gpu clock %lu Hz, GPU_RG_CNTRL %#x; fuse %d gate_reset %d mc_flush %d\n",
		 regulator_is_enabled(gp->vdd) ? "on" : "off",
		 regulator_get_voltage(gp->vdd), clk_get_rate(gp->clk),
		 gpu_rg_cntrl(), fuse, gate_reset, mc_flush);

	if (steps < 1)
		return 0;
	if (uv) {
		err = regulator_set_voltage(gp->vdd, uv, uv);
		dev_info(dev, "before step 1: vdd set to %d uV: %d, now %d uV\n",
			 uv, err, regulator_get_voltage(gp->vdd));
		if (err)
			return 0;
	}
	dev_info(dev, "step 1: enabling vdd-gpu\n");
	step_pause();
	err = regulator_enable(gp->vdd);
	if (err) {
		dev_err(dev, "step 1: regulator_enable: %d\n", err);
		return 0;
	}
	gp->done = 1;
	dev_info(dev, "step 1 done: vdd %s at %d uV\n",
		 regulator_is_enabled(gp->vdd) ? "on" : "off",
		 regulator_get_voltage(gp->vdd));
	show_pwm(dev);
	step_pause();

	if (steps < 2)
		return 0;
	dev_info(dev, "step 2: enabling the gpu, ref%s and pwr clocks, pwr at 204 MHz\n",
		 fuse ? ", fuse" : "");
	step_pause();
	err = clk_prepare_enable(gp->clk);
	if (!err)
		err = clk_prepare_enable(gp->clk_ref);
	if (!err)
		err = clk_prepare_enable(gp->clk_pwr);
	if (!err && gp->clk_fuse)
		err = clk_prepare_enable(gp->clk_fuse);
	if (err) {
		dev_err(dev, "step 2: clk_prepare_enable: %d\n", err);
		return 0;
	}
	clk_set_rate(gp->clk_pwr, 204000000);
	udelay(10);
	gp->done = 2;
	dev_info(dev, "step 2 done: gpu %lu Hz, ref %lu Hz, pwr %lu Hz, fuse %lu Hz\n",
		 clk_get_rate(gp->clk), clk_get_rate(gp->clk_ref),
		 clk_get_rate(gp->clk_pwr), gp->clk_fuse ? clk_get_rate(gp->clk_fuse) : 0);
	step_pause();

	if (steps < 3)
		return 0;
	dev_info(dev, "step 3: asserting the gpu reset\n");
	step_pause();
	reset_control_assert(gp->rst);
	udelay(10);
	gp->done = 3;
	dev_info(dev, "step 3 done\n");
	step_pause();

	if (steps < 4)
		return 0;
	dev_info(dev, "step 4: removing the clamps (GPU_RG_CNTRL %#x)\n", gpu_rg_cntrl());
	step_pause();
	tegra_pmc_powergate_remove_clamping(gp->pmc, TEGRA_POWERGATE_3D);
	udelay(10);
	gp->done = 4;
	dev_info(dev, "step 4 done: GPU_RG_CNTRL %#x\n", gpu_rg_cntrl());
	step_pause();

	if (steps < 5)
		return 0;
	dev_info(dev, "step 5: releasing the gpu reset%s%s\n",
		 gate_reset ? " with the gpu clock stopped" : "",
		 mc_flush ? ", then the MC flush" : "");
	step_pause();
	if (gate_reset)
		clk_disable(gp->clk);
	reset_control_deassert(gp->rst);
	if (gate_reset)
		clk_enable(gp->clk);
	udelay(10);
	if (mc_flush)
		flush_mc(dev);
	gp->done = 5;
	dev_info(dev, "step 5 done\n");
	step_pause();

	if (steps < 6)
		return 0;
	dev_info(dev, "step 6: reading BOOT_1 and BOOT_0\n");
	step_pause();
	boot1 = readl(gp->regs + 0x000004);
	dev_info(dev, "  BOOT_1 %#010x\n", boot1);
	boot0 = readl(gp->regs + 0x000000);
	gp->done = 6;
	dev_info(dev, "step 6 done: BOOT_0 %#010x\n", boot0);
	return 0;
}

/* Undone as nvgpu railgates: the clamps on, the reset, the clocks, the rail */
static void gpu_probe_remove(struct platform_device *pdev)
{
	struct gpu_probe *gp = platform_get_drvdata(pdev);

	if (gp->done >= 4) {
		set_gpu_rg_cntrl(1);
		udelay(10);
	}
	if (gp->done >= 3) {
		reset_control_assert(gp->rst);
		udelay(10);
	}
	if (gp->done >= 2) {
		if (gp->clk_fuse)
			clk_disable_unprepare(gp->clk_fuse);
		clk_disable_unprepare(gp->clk_pwr);
		clk_disable_unprepare(gp->clk_ref);
		clk_disable_unprepare(gp->clk);
		udelay(10);
	}
	if (gp->done >= 1)
		regulator_disable(gp->vdd);
	if (gp->clk_fuse)
		clk_put(gp->clk_fuse);
	dev_info(&pdev->dev, "powered down after %d steps, GPU_RG_CNTRL %#x\n",
		 gp->done, gpu_rg_cntrl());
}

static const struct of_device_id gpu_probe_of_match[] = {
	{ .compatible = "nvidia,gm20b" },
	{ }
};

static struct platform_driver gpu_probe_driver = {
	.driver = {
		.name = "gpu-power-probe",
		.of_match_table = gpu_probe_of_match,
	},
	.probe = gpu_probe_probe,
	.remove = gpu_probe_remove,
};
module_platform_driver(gpu_probe_driver);

MODULE_DESCRIPTION("Power the Tegra210 GPU up step by step, as nouveau does");
MODULE_LICENSE("GPL");
