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
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/klog.h>
#include <sys/mman.h>
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

/*
 * The display hardware, printed as U-Boot prints it from cboot's setup
 * (board/nvidia/p2894/p2894.c), to compare
 */
#define CAR_BASE		0x60006000UL
#define CAR_RST_DEVICES_L	0x004
#define CAR_CLK_OUT_ENB_L	0x010
#define  CAR_L_DISP1		27
#define CAR_PLLD_BASE		0x0d0
#define CAR_PLLD2_BASE		0x4b8
#define CAR_PLLDP_BASE		0x590
#define CAR_CLK_SOURCE_DISP1	0x138
#define CAR_CLK_SOURCE_SOR1	0x410
#define DC_BASE			0x54200000UL
#define DC_CMD_DISPLAY_COMMAND		0x032
#define DC_CMD_DISPLAY_POWER_CONTROL	0x036
#define DC_CMD_STATE_CONTROL		0x041
#define DC_DISP_DISP_CLOCK_CONTROL	0x42e

/* CAR clock-enable and reset registers of the clock banks L, H, U, V, W, X, Y */
static const unsigned int car_enb[] = { 0x010, 0x014, 0x018, 0x360, 0x364, 0x280, 0x298 };
static const unsigned int car_rst[] = { 0x004, 0x008, 0x00c, 0x358, 0x35c, 0x28c, 0x2a4 };

/* The display blocks, by CAR clock ID (dt-bindings/clock/tegra210-car.h) */
static const struct {
	const char *name;
	unsigned int id;
} display_clocks[] = {
	{ "DISP1", 27 }, { "DISP2", 26 }, { "HOST1X", 28 }, { "DSIA", 48 },
	{ "MIPI_CAL", 56 }, { "DPAUX", 181 }, { "SOR0", 182 }, { "SOR1", 183 },
	{ "DPAUX1", 207 }, { "SOR_SAFE", 222 },
};

static volatile uint32_t *map_regs(int fd, unsigned long base, size_t size)
{
	void *p = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, base);

	return p == MAP_FAILED ? NULL : p;
}

static void show_display_hw(void)
{
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	volatile uint32_t *car, *dc;
	char line[256] = "";
	unsigned int i, bank, bit, len = 0;

	car = fd < 0 ? NULL : map_regs(fd, CAR_BASE, 0x1000);
	if (!car) {
		say("display hardware: cannot map the CAR: %m");
		if (fd >= 0)
			close(fd);
		return;
	}

	for (i = 0; i < sizeof(display_clocks) / sizeof(display_clocks[0]); i++) {
		bank = display_clocks[i].id / 32;
		bit = display_clocks[i].id % 32;
		len += snprintf(line + len, sizeof(line) - len, "%s %u/%u ",
				display_clocks[i].name,
				car[car_enb[bank] / 4] >> bit & 1,
				car[car_rst[bank] / 4] >> bit & 1);
	}
	say("clocks: %s(clock on/in reset)", line);
	say("PLLs: D %08x D2 %08x DP %08x, DISP1 src %08x, SOR1 src %08x",
	    car[CAR_PLLD_BASE / 4], car[CAR_PLLD2_BASE / 4],
	    car[CAR_PLLDP_BASE / 4], car[CAR_CLK_SOURCE_DISP1 / 4],
	    car[CAR_CLK_SOURCE_SOR1 / 4]);

	/* Display controller A, only while it is clocked and out of reset */
	if (car[CAR_CLK_OUT_ENB_L / 4] >> CAR_L_DISP1 & 1 &&
	    !(car[CAR_RST_DEVICES_L / 4] >> CAR_L_DISP1 & 1) &&
	    (dc = map_regs(fd, DC_BASE, 0x2000)))
		say("DC A: command %08x power %08x state %08x clock %08x",
		    dc[DC_CMD_DISPLAY_COMMAND], dc[DC_CMD_DISPLAY_POWER_CONTROL],
		    dc[DC_CMD_STATE_CONTROL], dc[DC_DISP_DISP_CLOCK_CONTROL]);
	else
		say("DC A: not clocked, in reset or not mappable");
	close(fd);
}

/* The PMC's view of its power partitions, read through the secure monitor */
static void show_powergates(void)
{
	char line[128], name[32], state[16], on[320] = "", off[320] = "";
	FILE *f = fopen("/sys/kernel/debug/powergate", "r");
	char *list;

	if (!f) {
		say("powergates: cannot read /sys/kernel/debug/powergate");
		return;
	}
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "%31s %15s", name, state) != 2 ||
		    !strcmp(name, "powergate") || name[0] == '-')
			continue;
		list = strcmp(state, "yes") ? off : on;
		snprintf(list + strlen(list), sizeof(on) - strlen(list), "%s ",
			 name);
	}
	fclose(f);
	say("powergates on: %s", on);
	say("powergates off: %s", off);
}

/* The power domains as Linux tracks them */
static void show_genpd(void)
{
	char line[256], name[48], state[24], out[400] = "";
	FILE *f = fopen("/sys/kernel/debug/pm_genpd/pm_genpd_summary", "r");

	if (!f) {
		say("power domains: cannot read pm_genpd_summary");
		return;
	}
	while (fgets(line, sizeof(line), f))
		if (line[0] != ' ' && line[0] != '-' &&
		    strncmp(line, "domain", 6) &&
		    sscanf(line, "%47s %23s", name, state) == 2)
			snprintf(out + strlen(out), sizeof(out) - strlen(out),
				 "%s %s; ", name, state);
	fclose(f);
	say("power domains: %s", out);
}

/* The display clocks as the clock framework sees them */
static const char *const display_clk_names[] = {
	"pll_d", "pll_d_out0", "pll_d2", "pll_d2_out0", "pll_dp", "disp1",
	"sor1", "sor1_out", "sor_safe", "host1x", "dpaux1",
};

static void show_clks(void)
{
	const unsigned int count = sizeof(display_clk_names) / sizeof(display_clk_names[0]);
	char line[400], out[2][300] = { "", "" }, *tok[9], *save;
	FILE *f = fopen("/sys/kernel/debug/clk/clk_summary", "r");
	bool seen[sizeof(display_clk_names) / sizeof(display_clk_names[0])] = { 0 };
	unsigned int i, n;
	char *half;

	if (!f) {
		say("clock framework: cannot read clk_summary");
		return;
	}
	/* name, enable, prepare and protect counts, rate, accuracy, phase, duty, hw */
	while (fgets(line, sizeof(line), f)) {
		n = 0;
		for (tok[n] = strtok_r(line, " \t\n", &save); tok[n] && ++n < 9;
		     tok[n] = strtok_r(NULL, " \t\n", &save))
			;
		if (n < 9)
			continue;
		for (i = 0; i < count; i++) {
			if (seen[i] || strcmp(tok[0], display_clk_names[i]))
				continue;
			seen[i] = true;
			half = out[i >= count / 2];
			snprintf(half + strlen(half), sizeof(out[0]) - strlen(half),
				 "%s en %s %s Hz hw %s; ", tok[0], tok[1], tok[4],
				 tok[8]);
		}
	}
	fclose(f);
	say("clock framework: %s", out[0]);
	say("clock framework: %s", out[1]);
}

static void read_attr(const char *dev, const char *attr, char *buf, int len)
{
	char path[300];
	FILE *f;

	snprintf(path, sizeof(path), "/sys/class/regulator/%s/%s", dev, attr);
	f = fopen(path, "r");
	if (!f || !fgets(buf, len, f))
		snprintf(buf, len, "-");
	if (f)
		fclose(f);
	buf[strcspn(buf, "\n")] = 0;
}

/* Every regulator's voltage and state, four to a line */
static void show_regulators(void)
{
	char name[48], uv[16], state[16], line[400] = "";
	DIR *d = opendir("/sys/class/regulator");
	struct dirent *e;
	int n = 0, len;

	if (!d) {
		say("regulators: cannot read /sys/class/regulator");
		return;
	}
	while ((e = readdir(d))) {
		if (strncmp(e->d_name, "regulator.", 10))
			continue;
		read_attr(e->d_name, "name", name, sizeof(name));
		read_attr(e->d_name, "microvolts", uv, sizeof(uv));
		read_attr(e->d_name, "state", state, sizeof(state));
		len = strlen(line);
		snprintf(line + len, sizeof(line) - len, "%s%s %s %s",
			 n % 4 ? "; " : "", name, uv, state);
		if (++n % 4 == 0) {
			say("regulators: %s", line);
			line[0] = 0;
		}
	}
	if (n % 4)
		say("regulators: %s", line);
	closedir(d);
}

/* Kernel messages worth seeing again at the end of the log */
static const char *const keys[] = {
	"error", "fail", "warn", "unable", "timeout", "invalid", "bug:",
	"oops", "drm", "simple", "framebuffer", "frame buffer", "regulator",
	"pmc", "powergate", "smmu", "reserved mem", "bringing",
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
	mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);
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

	/* The most telling lines last: U-Boot shows the end of the log */
	show_highlights();
	show_regulators();
	show_clks();
	show_genpd();
	show_powergates();
	show_display();
	show_display_hw();
	say("rebooting into the recovery slot, where U-Boot shows this log");
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, "recovery");
	say("reboot failed: %m");
	for (;;)
		pause();
}
