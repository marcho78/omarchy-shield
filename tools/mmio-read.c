// SPDX-License-Identifier: GPL-2.0
/*
 * Reads 32-bit registers through /dev/mem, read-only, to compare what cboot
 * left in the hardware with what a mainline driver would program:
 *
 *   mmio-read <base> <word index>...
 *
 * prints "<address> [<index>] <value>" for each, in hex. The base must be
 * page aligned. Only read blocks whose clock runs and which are out of
 * reset (clk_summary's "hardware enable"): on Tegra, reading a clock-gated
 * block hangs the bus. mmap() it is: read() on /dev/mem is not safe for
 * device memory on arm64.
 *
 * Build: aarch64-linux-gnu-gcc -static -O2 -Wall -o build/mmio-read tools/mmio-read.c
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	unsigned long base, index, top = 0, page = sysconf(_SC_PAGESIZE);
	volatile const uint32_t *regs;
	size_t span;
	int fd, i;

	if (argc < 3) {
		fprintf(stderr, "usage: %s <base> <word index>...\n", argv[0]);
		return 2;
	}
	base = strtoul(argv[1], NULL, 0);
	if (base % page) {
		fprintf(stderr, "%#lx is not page aligned\n", base);
		return 2;
	}
	for (i = 2; i < argc; i++) {
		index = strtoul(argv[i], NULL, 0);
		if (index > top)
			top = index;
	}
	span = ((top + 1) * 4 + page - 1) / page * page;

	fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	regs = mmap(NULL, span, PROT_READ, MAP_SHARED, fd, base);
	if (regs == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	for (i = 2; i < argc; i++) {
		index = strtoul(argv[i], NULL, 0);
		printf("%#010lx [%#05lx] %#010x\n", base + index * 4, index, regs[index]);
	}
	return 0;
}
