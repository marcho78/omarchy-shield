// SPDX-License-Identifier: MIT
/*
 * The first init on the SHIELD TV 2017: report that Linux runs and what it
 * sees, then reboot into the recovery slot after a minute. Everything goes
 * into the kernel log, which reaches the HDMI console and ramoops; after the
 * reboot U-Boot shows the end of the log on the TV, so the report survives
 * a kernel that could not keep the screen. It is the whole userspace of the
 * first payload (scripts/12); a real root filesystem comes later.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/klog.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>

#define REBOOT_AT		60	/* seconds of uptime */
#define HIGHLIGHTS		30	/* kernel messages repeated at the end */
#define SYSLOG_ACTION_READ_ALL	3

static int kmsg = -1;

/* One line into the kernel log, which every console shows; stdout without it */
static void say(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int n;

	n = snprintf(line, sizeof(line), "darcy-init: ");
	va_start(ap, fmt);
	vsnprintf(line + n, sizeof(line) - n, fmt, ap);
	va_end(ap);

	n = strcspn(line, "\n");
	line[n] = '\n';
	if (kmsg < 0 || write(kmsg, line, n + 1) < 0)
		fwrite(line, 1, n + 1, stdout);
}

static void show(const char *title, const char *path, int max_lines)
{
	char line[400];
	FILE *f = fopen(path, "r");
	int n = 0;

	if (!f) {
		say("%s: cannot read %s", title, path);
		return;
	}
	say("%s:", title);
	while ((!max_lines || n++ < max_lines) && fgets(line, sizeof(line), f))
		say("  %s", line);
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

	say("%s:%s", title, d ? "" : " none");
	while (d && (e = readdir(d)))
		if (e->d_name[0] != '.')
			say("  %s/%s", dir, e->d_name);
	if (d)
		closedir(d);
}

static double uptime(void)
{
	FILE *f = fopen("/proc/uptime", "r");
	double up = 0;

	if (f) {
		if (fscanf(f, "%lf", &up) != 1)
			up = 0;
		fclose(f);
	}
	return up;
}

/* Whether a driver took over the framebuffer U-Boot handed on */
static void show_display(void)
{
	char name[64] = "missing", driver[256] = "";
	FILE *f = fopen("/sys/class/graphics/fb0/name", "r");
	const char *slash;
	ssize_t n;

	if (f) {
		if (!fgets(name, sizeof(name), f))
			strcpy(name, "unnamed");
		name[strcspn(name, "\n")] = 0;
		fclose(f);
	}
	n = readlink("/sys/class/drm/card0/device/driver", driver,
		     sizeof(driver) - 1);
	driver[n > 0 ? n : 0] = 0;
	slash = strrchr(driver, '/');
	say("display: fb0 %s, DRM card0 %s", name,
	    n <= 0 ? "missing" : slash ? slash + 1 : driver);
}

/* Kernel messages worth seeing again at the end of the log */
static const char *const keys[] = {
	"error", "fail", "warn", "unable", "timeout", "invalid", "bug:",
	"oops", "drm", "simple", "framebuffer", "frame buffer", "regulator",
	"pmc", "powergate", "smmu", "reserved mem",
};

static bool highlight(const char *line)
{
	size_t i;

	for (i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
		if (strcasestr(line, keys[i]))
			return true;
	return false;
}

static void show_highlights(void)
{
	static char log[1 << 20];
	const char *ring[HIGHLIGHTS];
	char *line, *save;
	int len, n = 0, i;

	len = klogctl(SYSLOG_ACTION_READ_ALL, log, sizeof(log) - 1);
	if (len < 0) {
		say("kernel log: cannot read it: %m");
		return;
	}
	log[len] = 0;

	for (line = strtok_r(log, "\n", &save); line;
	     line = strtok_r(NULL, "\n", &save)) {
		if (line[0] == '<' && strchr(line, '>'))
			line = strchr(line, '>') + 1;
		if (!strstr(line, "darcy-init:") && highlight(line))
			ring[n++ % HIGHLIGHTS] = line;
	}

	say("kernel messages to look at: %d, the last %d of them follow", n,
	    n < HIGHLIGHTS ? n : HIGHLIGHTS);
	for (i = n < HIGHLIGHTS ? 0 : n - HIGHLIGHTS; i < n; i++)
		say("| %s", ring[i % HIGHLIGHTS]);
}

int main(void)
{
	double up;

	setvbuf(stdout, NULL, _IONBF, 0);

	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("pstore", "/sys/fs/pstore", "pstore", 0, NULL);
	kmsg = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);

	say("==============================================");
	say("  Linux is up on the SHIELD TV 2017 (darcy)");
	say("==============================================");
	show("kernel", "/proc/version", 0);
	show("device tree model", "/sys/firmware/devicetree/base/model", 0);
	say("cpus online: %d", count_cpus());
	show("memory", "/proc/meminfo", 2);
	show_display();
	show_dir("crash logs kept from the previous boot", "/sys/fs/pstore");

	while ((up = uptime()) < REBOOT_AT) {
		say("uptime %.0f s; rebooting into the recovery slot at %d s",
		    up, REBOOT_AT);
		sleep(up + 15 < REBOOT_AT ? 15 : (unsigned int)(REBOOT_AT - up) + 1);
	}

	show_display();
	show_highlights();
	say("rebooting into the recovery slot, where U-Boot shows this log");
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, "recovery");
	say("reboot failed: %m");
	for (;;)
		pause();
}
