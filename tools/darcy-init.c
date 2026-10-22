// SPDX-License-Identifier: MIT
/*
 * The first init on the SHIELD TV 2017: show on the HDMI console that Linux
 * runs and what it sees, then keep reporting so a frozen screen is obvious.
 * It is the whole userspace of the first payload (scripts/12); a real root
 * filesystem comes later.
 */
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

static void show(const char *title, const char *path, int max_lines)
{
	char line[512];
	FILE *f = fopen(path, "r");
	int n = 0;

	printf("--- %s\n", title);
	if (!f) {
		printf("    (cannot read %s)\n", path);
		return;
	}
	while (fgets(line, sizeof(line), f) && (!max_lines || n++ < max_lines))
		printf("    %s%s", line, strchr(line, '\n') ? "" : "\n");
	fclose(f);
}

static int count_cpus(void)
{
	char line[256];
	FILE *f = fopen("/proc/cpuinfo", "r");
	int n = 0;

	while (f && fgets(line, sizeof(line), f))
		n += !strncmp(line, "processor", 9);
	if (f)
		fclose(f);
	return n;
}

static void show_dir(const char *title, const char *dir)
{
	struct dirent *e;
	DIR *d = opendir(dir);

	printf("--- %s\n", title);
	if (!d) {
		printf("    (none)\n");
		return;
	}
	while ((e = readdir(d)))
		if (e->d_name[0] != '.')
			printf("    %s/%s\n", dir, e->d_name);
	closedir(d);
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);

	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("pstore", "/sys/fs/pstore", "pstore", 0, NULL);

	printf("\n==============================================\n");
	printf("  Linux is up on the SHIELD TV 2017 (darcy)\n");
	printf("==============================================\n");
	show("kernel", "/proc/version", 0);
	show("command line", "/proc/cmdline", 0);
	show("device tree model", "/sys/firmware/devicetree/base/model", 0);
	printf("--- cpus online: %d\n", count_cpus());
	show("memory", "/proc/meminfo", 3);
	show_dir("crash logs kept from the previous boot", "/sys/fs/pstore");

	for (;;) {
		sleep(30);
		show("uptime (seconds)", "/proc/uptime", 0);
	}
}
