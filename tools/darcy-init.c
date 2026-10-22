// SPDX-License-Identifier: MIT
/*
 * The first init on the SHIELD TV 2017: report that Linux runs and what it
 * sees, then reboot into the recovery slot after a minute. Everything goes
 * into the kernel log, which reaches the HDMI console and ramoops; after the
 * reboot U-Boot shows the end of the log on the TV, so the report survives
 * a kernel that could not keep the screen, then goes to fastboot for the
 * next image. It is the whole userspace of the first payload (scripts/12); a
 * real root filesystem comes later.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/klog.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#define REBOOT_AT		60	/* seconds of uptime */
/*
 * The reboot command: "recovery" goes straight back to U-Boot, which shows
 * this log and then reboots into the bootloader menu (fastboot), ready for
 * the next image. "bootloader" goes to that menu directly, but the menu
 * clears the RAM the log is kept in.
 */
#define REBOOT_INTO		"recovery"
/*
 * Freeze instead of rebooting, to prove the watchdog U-Boot arms
 * (darcy_watchdog) resets a kernel that hangs without a panic.
 */
#define WATCHDOG_TEST		0
/*
 * The display registers, as U-Boot prints them from cboot's setup. They
 * found why HDMI went dark; while nothing changes there, they stay out of
 * the report to leave room in what U-Boot shows.
 */
#define DISPLAY_REPORT		0
#define HIGHLIGHTS		16	/* kernel messages repeated at the end */
#define BLUETOOTH_LINES		8	/* and the Bluetooth ones, separately */
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
#define CAR_PLLD2_MISC0		0x4bc
#define CAR_PLLDP_BASE		0x590
#define CAR_CLK_SOURCE_DISP1	0x138
#define CAR_CLK_SOURCE_SOR1	0x410
#define DC_BASE			0x54200000UL
/* The HDMI pins' pinmux words; bit 5 parks the pin */
#define PINMUX_BASE		0x70003000UL
#define PINMUX_HDMI_CEC		0x198
#define PINMUX_HDMI_HPD		0x19c
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
	volatile uint32_t *car, *dc, *pins;
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
	say("PLLs: D %08x D2 %08x (misc0 %08x) DP %08x, DISP1 src %08x, SOR1 src %08x",
	    car[CAR_PLLD_BASE / 4], car[CAR_PLLD2_BASE / 4],
	    car[CAR_PLLD2_MISC0 / 4], car[CAR_PLLDP_BASE / 4],
	    car[CAR_CLK_SOURCE_DISP1 / 4], car[CAR_CLK_SOURCE_SOR1 / 4]);
	if ((pins = map_regs(fd, PINMUX_BASE, 0x1000)))
		say("pins: HDMI HPD pin %08x, CEC pin %08x",
		    pins[PINMUX_HDMI_HPD / 4], pins[PINMUX_HDMI_CEC / 4]);

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

static void read_line(const char *path, char *buf, int len)
{
	FILE *f = fopen(path, "r");

	if (!f || !fgets(buf, len, f))
		snprintf(buf, len, "-");
	if (f)
		fclose(f);
	buf[strcspn(buf, "\n")] = 0;
}

static void read_attr(const char *dev, const char *attr, char *buf, int len)
{
	char path[300];

	snprintf(path, sizeof(path), "/sys/class/regulator/%s/%s", dev, attr);
	read_line(path, buf, len);
}

/* USB devices (not their interfaces): port, vendor:product, name */
static void show_usb(void)
{
	char path[300], vid[8], pid[8], product[64];
	DIR *d = opendir("/sys/bus/usb/devices");
	struct dirent *e;
	int n = 0;

	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.' || strchr(e->d_name, ':'))
			continue;
		snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/idVendor", e->d_name);
		read_line(path, vid, sizeof(vid));
		snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/idProduct", e->d_name);
		read_line(path, pid, sizeof(pid));
		snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/product", e->d_name);
		read_line(path, product, sizeof(product));
		say("usb %s: %s:%s %s", e->d_name, vid, pid, product);
		n++;
	}
	if (d)
		closedir(d);
	if (!n)
		say("usb: no devices");
}

/*
 * Hub ports that saw an over-current: a device that draws more than its
 * hub gives, as a disk behind a hub on the SHIELD's port may
 */
static void show_usb_ports(void)
{
	char dir[300], path[600], count[16], line[400] = "";
	DIR *d = opendir("/sys/bus/usb/devices"), *p;
	struct dirent *e, *port;

	while (d && (e = readdir(d))) {
		if (!strchr(e->d_name, ':'))
			continue;
		snprintf(dir, sizeof(dir), "/sys/bus/usb/devices/%s", e->d_name);
		p = opendir(dir);
		while (p && (port = readdir(p))) {
			if (!strstr(port->d_name, "-port"))
				continue;
			snprintf(path, sizeof(path), "%s/%s/over_current_count",
				 dir, port->d_name);
			read_line(path, count, sizeof(count));
			if (strcmp(count, "0") && strcmp(count, "-"))
				snprintf(line + strlen(line), sizeof(line) - strlen(line),
					 "%s %s; ", port->d_name, count);
		}
		if (p)
			closedir(p);
	}
	if (d)
		closedir(d);
	say("usb over-currents: %s", line[0] ? line : "none");
}

/* Input devices by name, which shows a USB keyboard */
static void show_inputs(void)
{
	char line[256], names[400] = "";
	FILE *f = fopen("/proc/bus/input/devices", "r");
	size_t len;

	while (f && fgets(line, sizeof(line), f)) {
		if (strncmp(line, "N: Name=", 8))
			continue;
		line[strcspn(line, "\n")] = 0;
		len = strlen(names);
		snprintf(names + len, sizeof(names) - len, "%s ", line + 8);
	}
	if (f)
		fclose(f);
	say("input devices: %s", names[0] ? names : "none");
}

/* Network interfaces: name, driver, MAC address, link state */
static void show_net(void)
{
	char path[300], addr[32], state[16], driver[256];
	DIR *d = opendir("/sys/class/net");
	struct dirent *e;
	const char *slash;
	ssize_t len;
	int n = 0;

	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.' || !strcmp(e->d_name, "lo"))
			continue;
		snprintf(path, sizeof(path), "/sys/class/net/%s/address", e->d_name);
		read_line(path, addr, sizeof(addr));
		snprintf(path, sizeof(path), "/sys/class/net/%s/operstate", e->d_name);
		read_line(path, state, sizeof(state));
		snprintf(path, sizeof(path), "/sys/class/net/%s/device/driver", e->d_name);
		len = readlink(path, driver, sizeof(driver) - 1);
		driver[len > 0 ? len : 0] = 0;
		slash = strrchr(driver, '/');
		say("net %s: %s %s %s", e->d_name,
		    len <= 0 ? "-" : slash ? slash + 1 : driver, addr, state);
		n++;
	}
	if (d)
		closedir(d);
	if (!n)
		say("net: no interfaces");
}

/* Kernel messages worth seeing again at the end of the log */
static const char *const keys[] = {
	"error", "fail", "warn", "unable", "timeout", "invalid", "bug:",
	"oops", "drm", "simple", "framebuffer", "frame buffer", "regulator",
	"pmc", "powergate", "smmu", "reserved mem", "bringing", "xhci", "xusb",
	"padctl", "firmware", "brcmf", "r8169", "pcie", "sdio", "wdt",
	"over-current", "cannot enable", NULL
};

/* What the Bluetooth core, hci_bcm and the chip's UART (UARTD) say */
static const char *const bluetooth_keys[] = {
	"bluetooth", "hci0", "hci_uart", "serial0", "70006300", NULL
};

static bool matches(const char *line, const char *const *keys)
{
	for (; keys && *keys; keys++)
		if (strcasestr(line, *keys))
			return true;
	return false;
}

/* The last max kernel messages with one of keys and none of except */
static void show_messages(const char *title, const char *const *keys,
			  const char *const *except, int max)
{
	static char log[1 << 20];
	const char *ring[max];
	char *line, *save;
	int len, n = 0, i;

	len = klogctl(SYSLOG_ACTION_READ_ALL, log, sizeof(log) - 1);
	if (len < 0) {
		say("%s: cannot read the kernel log: %m", title);
		return;
	}
	log[len] = 0;

	for (line = strtok_r(log, "\n", &save); line;
	     line = strtok_r(NULL, "\n", &save)) {
		if (line[0] == '<' && strchr(line, '>'))
			line = strchr(line, '>') + 1;
		if (!strstr(line, "darcy-init:") && matches(line, keys) &&
		    !matches(line, except))
			ring[n++ % max] = line;
	}

	say("%s: %d, the last %d of them follow", title, n, n < max ? n : max);
	for (i = n < max ? 0 : n - max; i < n; i++)
		say("| %s", ring[i % max]);
}

/* The driver bound to a device, by its sysfs path; NULL if none */
static const char *driver_of(const char *dev, char *buf, size_t len)
{
	char path[300];
	const char *slash;
	ssize_t n;

	snprintf(path, sizeof(path), "%s/driver", dev);
	n = readlink(path, buf, len - 1);
	if (n <= 0)
		return NULL;
	buf[n] = 0;
	slash = strrchr(buf, '/');
	return slash ? slash + 1 : buf;
}

/* Devices whose probe waits for something, and for what */
static void show_deferred(void)
{
	char line[300];
	FILE *f = fopen("/sys/kernel/debug/devices_deferred", "r");
	int n = 0;

	if (!f) {
		say("deferred probes: cannot read devices_deferred");
		return;
	}
	while (n < 8 && fgets(line, sizeof(line), f)) {
		say("deferred probe: %s", line);
		n++;
	}
	fclose(f);
	if (!n)
		say("deferred probes: none");
}

/* From the kernel's include/net/bluetooth/hci_sock.h */
#define BTPROTO_HCI		1
#define HCIGETDEVINFO		_IOR('H', 211, int)
#define HCI_UP			0	/* bit in hci_dev_info.flags */

struct hci_dev_info {
	uint16_t dev_id;
	char name[8];
	uint8_t bdaddr[6];	/* least significant byte first */
	uint32_t flags;
	uint8_t type;
	uint8_t features[8];
	uint32_t pkt_type, link_policy, link_mode;
	uint16_t acl_mtu, acl_pkts, sco_mtu, sco_pkts;
	uint32_t stat[10];
};

/*
 * A Bluetooth adapter: the address the chip reports, and whether the
 * kernel initialised it. It does not while the adapter lacks a valid
 * address of its own ("unconfigured"), and only that init creates the
 * adapter's debugfs files, features among them.
 */
static void show_adapter(int sock, const char *name)
{
	struct hci_dev_info di = { .dev_id = atoi(name + strlen("hci")) };
	const uint8_t *a = di.bdaddr;
	char dir[300], path[320];
	const char *init;

	if (sock < 0 || ioctl(sock, HCIGETDEVINFO, &di) < 0) {
		say("bluetooth %s: cannot read its address: %m", name);
		return;
	}
	/* The adapter's debugfs directory comes with it; features only with init */
	snprintf(dir, sizeof(dir), "/sys/kernel/debug/bluetooth/%s", name);
	snprintf(path, sizeof(path), "%s/features", dir);
	if (access(dir, F_OK))
		init = "initialisation unknown (no debugfs)";
	else if (access(path, F_OK))
		init = "not initialised (unconfigured?)";
	else
		init = "initialised";
	say("bluetooth %s: %02X:%02X:%02X:%02X:%02X:%02X, %s, %s", name,
	    a[5], a[4], a[3], a[2], a[1], a[0],
	    di.flags & 1 << HCI_UP ? "up" : "down", init);
}

/*
 * Bluetooth adapters, then the way there: UARTD's driver, the serdev
 * device hci_bcm binds to, probes still waiting, and what the kernel said
 * about all of it
 */
static void show_bluetooth(void)
{
	int sock = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
	char path[300], driver[256], line[400];
	DIR *d = opendir("/sys/class/bluetooth");
	const char *name;
	struct dirent *e;
	int n = 0;

	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.' || strchr(e->d_name, ':'))
			continue;
		show_adapter(sock, e->d_name);
		n++;
	}
	if (d)
		closedir(d);
	if (sock >= 0)
		close(sock);
	if (!n)
		say("bluetooth: no adapters");

	name = driver_of("/sys/bus/platform/devices/70006300.serial", driver,
			 sizeof(driver));
	snprintf(line, sizeof(line), "UART 70006300.serial: driver %s",
		 name ? name : "none");
	/* serdev devices are named after their controller: serial0-0 */
	d = opendir("/sys/bus/serial/devices");
	while (d && (e = readdir(d))) {
		if (!strchr(e->d_name, '-'))
			continue;
		snprintf(path, sizeof(path), "/sys/bus/serial/devices/%s", e->d_name);
		name = driver_of(path, driver, sizeof(driver));
		snprintf(line + strlen(line), sizeof(line) - strlen(line),
			 "; serdev %s: driver %s", e->d_name, name ? name : "none");
	}
	if (d)
		closedir(d);
	say("bluetooth %s", line);
	show_deferred();
	show_messages("Bluetooth kernel messages", bluetooth_keys, NULL,
		      BLUETOOTH_LINES);
}

/* Disks other than the eMMC, as a USB drive appears */
static void show_disks(void)
{
	char path[300], vendor[32], model[64], size[32];
	DIR *d = opendir("/sys/block");
	struct dirent *e;
	int n = 0;

	while (d && (e = readdir(d))) {
		if (strncmp(e->d_name, "sd", 2))
			continue;
		snprintf(path, sizeof(path), "/sys/block/%s/device/vendor", e->d_name);
		read_line(path, vendor, sizeof(vendor));
		snprintf(path, sizeof(path), "/sys/block/%s/device/model", e->d_name);
		read_line(path, model, sizeof(model));
		snprintf(path, sizeof(path), "/sys/block/%s/size", e->d_name);
		read_line(path, size, sizeof(size));
		say("disk %s: %s %s, %.1f GB", e->d_name, vendor, model,
		    atof(size) * 512 / 1e9);
		n++;
	}
	if (d)
		closedir(d);
	if (!n)
		say("disks: none besides the eMMC");
}

/* One KEY=value from a uevent file, "-" if missing */
static void read_uevent(const char *path, const char *key, char *buf, int len)
{
	char line[256];
	FILE *f = fopen(path, "r");
	size_t keylen = strlen(key), n;

	snprintf(buf, len, "-");
	while (f && fgets(line, sizeof(line), f))
		if (!strncmp(line, key, keylen) && line[keylen] == '=') {
			n = strcspn(line + keylen + 1, "\n");
			if (n > (size_t)len - 1)
				n = len - 1;
			memcpy(buf, line + keylen + 1, n);
			buf[n] = 0;
			break;
		}
	if (f)
		fclose(f);
}

/*
 * The eMMC as Linux reads it: its size and partition table, eight
 * partitions to a line. The root filesystem is to live in one of them.
 * Without MMC aliases in the device tree the eMMC is not always mmcblk0,
 * so every whole MMC disk is listed.
 */
static void show_emmc(void)
{
	char path[300], size[32], name[40], line[400];
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;
	int i, disks = 0, parts;

	while (d && (e = readdir(d))) {
		if (strncmp(e->d_name, "mmcblk", 6) ||
		    strspn(e->d_name + 6, "0123456789") != strlen(e->d_name + 6))
			continue;
		snprintf(path, sizeof(path), "/sys/class/block/%s/size", e->d_name);
		read_line(path, size, sizeof(size));
		say("emmc %s: %.1f GiB, partitions:", e->d_name,
		    atof(size) / 2048 / 1024);
		line[0] = 0;
		parts = 0;
		for (i = 1; i <= 128; i++) {
			snprintf(path, sizeof(path), "/sys/class/block/%sp%d/uevent",
				 e->d_name, i);
			if (access(path, F_OK))
				continue;
			read_uevent(path, "PARTNAME", name, sizeof(name));
			snprintf(path, sizeof(path), "/sys/class/block/%sp%d/size",
				 e->d_name, i);
			read_line(path, size, sizeof(size));
			snprintf(line + strlen(line), sizeof(line) - strlen(line),
				 "p%d %s %.0fM; ", i, name, atof(size) / 2048);
			if (++parts % 8 == 0) {
				say("  %s", line);
				line[0] = 0;
			}
		}
		if (parts % 8)
			say("  %s", line);
		if (!parts)
			say("  none: Linux found no partition table");
		disks++;
	}
	if (d)
		closedir(d);
	if (!disks)
		say("emmc: no MMC disk");
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
	show_regulators();
	show_dir("crash logs kept from the previous boot", "/sys/fs/pstore");

	while ((up = uptime()) < REBOOT_AT) {
		say("uptime %.0f s; at %d s: report, then %s", up, REBOOT_AT,
		    WATCHDOG_TEST ? "freeze (watchdog test)" : "'reboot " REBOOT_INTO "'");
		sleep(up + 15 < REBOOT_AT ? 15 : (unsigned int)(REBOOT_AT - up) + 1);
	}

	/* The most telling lines last: U-Boot shows the end of the log */
	show_messages("kernel messages to look at", keys, bluetooth_keys,
		      HIGHLIGHTS);
	if (DISPLAY_REPORT) {
		show_clks();
		show_genpd();
	}
	show_usb();
	show_usb_ports();
	show_inputs();
	show_disks();
	show_emmc();
	show_net();
	show_bluetooth();
	show_display();
	if (DISPLAY_REPORT)
		show_display_hw();
	if (WATCHDOG_TEST) {
		say("freezing on purpose: the watchdog should reset the board 150 s after U-Boot started Linux");
		for (;;)
			pause();
	}
	say("'reboot %s'; U-Boot shows this log after the reboot", REBOOT_INTO);
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, REBOOT_INTO);
	say("reboot failed: %m");
	for (;;)
		pause();
}
