// SPDX-License-Identifier: GPL-2.0
/*
 * Reads PMC registers through the secure monitor, as the PMC driver does on
 * a TZ-only PMC (tegra_pmc_readl() in drivers/soc/tegra/pmc.c), to see
 * whether the monitor answers for an offset before a driver writes it.
 * Read-only: it prints each offset's SMC status and value to the kernel
 * log, then declines to stay loaded.
 *
 *   insmod pmc-read.ko offsets=0x38,0x2d4
 *
 * Build: tools/build-module.sh pmc-read
 */
#include <linux/arm-smccc.h>
#include <linux/module.h>

#define TEGRA_SMC_PMC		0xc2fffe00
#define TEGRA_SMC_PMC_READ	0xaa
#define TEGRA210_PMC_SIZE	0xc00

static unsigned int offsets[16];
static int num_offsets;
module_param_array(offsets, uint, &num_offsets, 0);
MODULE_PARM_DESC(offsets, "PMC register offsets to read, in bytes");

static int __init pmc_read_init(void)
{
	struct arm_smccc_res res;
	int i;

	for (i = 0; i < num_offsets; i++) {
		if (offsets[i] % 4 || offsets[i] >= TEGRA210_PMC_SIZE) {
			pr_info("pmc-read: %#x is not a PMC register\n", offsets[i]);
			continue;
		}
		arm_smccc_smc(TEGRA_SMC_PMC, TEGRA_SMC_PMC_READ, offsets[i],
			      0, 0, 0, 0, 0, &res);
		pr_info("pmc-read: %#05x: SMC status %lu, value %#010lx\n",
			offsets[i], res.a0, res.a1);
	}

	/* Nothing to keep loaded */
	return -EAGAIN;
}
module_init(pmc_read_init);

MODULE_DESCRIPTION("Read Tegra PMC registers through the secure monitor");
MODULE_LICENSE("GPL");
