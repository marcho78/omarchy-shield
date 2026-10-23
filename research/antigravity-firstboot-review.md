# First-Boot Review: Installed System on NVIDIA SHIELD TV (Darcy / p2894)

---

## (a) Is `module_blacklist=tegra_drm` the right and sufficient way to keep `simpledrm` alive?

### 1. Why `tegra_drm` killed HDMI in Boots 1 and 3 (Verified Fact)

When `systemd-udevd` processed uevents on the mounted root filesystem, `/host1x@50000000/dc@54200000` and `/host1x@50000000/dc@54240000` (which are left enabled by default in `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:192-220` and not disabled in `tegra210-p2894.dtsi` or `kernel/dts/darcy.dts`) advertised `MODALIAS=of:NdcT(null)Cnvidia,tegra210-dc`, and `host1x.ko` also declared `MODULE_SOFTDEP("post: tegra-drm")` (`vendor/linux/drivers/gpu/host1x/dev.c:827`). Loading `tegra-drm.ko` killed HDMI through **two independent mechanisms**:

1. **Physical hardware teardown in `tegra_dc_probe()`:**
   In `vendor/linux/drivers/gpu/drm/tegra/dc.c:3227-3349`, `tegra_dc_probe()` binds to `dc@54200000` (`DISP1`, which CBoot left actively scanning out the 1080p60 framebuffer to `SOR1`). Near the end of `tegra_dc_probe()` (`dc.c:3316-3345`), the driver unconditionally resets and powers off the display controller until a DRM atomic modeset re-enables it:
   ```c
   err = reset_control_assert(dc->rst);          // dc.c:3323 — asserts CAR reset 27 (DISP1)
   ...
   clk_disable_unprepare(dc->clk);               // dc.c:3331 — gates TEGRA210_CLK_DISP1
   ...
   tegra_pmc_powergate_power_off(dc->powergate); // dc.c:3344 — powers off TEGRA_POWERGATE_DIS (partition 18)
   ```
   Even if `simpledrm` were never evicted in software, `tegra_dc_probe()` physically kills the `DISP1` scanout engine and powers down the `DIS` partition.

2. **Software framebuffer eviction in `host1x_drm_probe()`:**
   Because `dc@54200000` and `dc@54240000` registered 2 CRTCs (`drm->mode_config.num_crtc == 2 > 0`) while `sor@54580000` has `status = "disabled"` (`tegra210.dtsi:353`), `host1x_drm_probe()` (`vendor/linux/drivers/gpu/drm/tegra/drm.c:1259-1260`) executed:
   ```c
   if (drm->mode_config.num_crtc > 0)
       aperture_remove_all_conflicting_devices(tegra_drm_driver.name);
   ```
   This evicted `simpledrm`, and `drm_client_setup()` then failed with `tegra-drm 50000000.host1x: [drm] Cannot find any crtc or sizes`, leaving 0 active displays.

### 2. Is `module_blacklist=tegra_drm` the right name and mechanism? (Verified Fact)

**Yes.**
- Although the `.ko` filename on disk is `tegra-drm.ko` (`vendor/linux/drivers/gpu/drm/tegra/Makefile:25`), Kbuild normalizes hyphens to underscores in `KBUILD_MODNAME`. In `build/linux/drivers/gpu/drm/tegra/tegra-drm.mod.c:9`, the embedded `struct module __this_module` name is:
  ```c
  .name = KBUILD_MODNAME, // "tegra_drm"
  ```
- In `vendor/linux/kernel/module/main.c:2936-2953` (`blacklisted()`) and `3406-3409` (`early_mod_check()`), the kernel's `finit_module`/`init_module` path checks `info->name` (`"tegra_drm"`) against the comma-separated `module_blacklist` cmdline parameter and returns `-EPERM` (`"Module tegra_drm is blacklisted\n"`).
- Userspace `libkmod` (`KMOD_PROBE_APPLY_BLACKLIST`, used by `systemd-udevd` and `modprobe -b`) also parses `module_blacklist=` from `/proc/cmdline` and normalizes `-`/`_`.
- Because `early_mod_check()` enforces this in the kernel syscall path, `module_blacklist=tegra_drm` blocks **every** module load path (both `udev` modalias autoloading and `host1x`'s `MODULE_SOFTDEP("post: tegra-drm")`).

### 3. Could `host1x`, `nouveau`, `snd-hda-tegra`, or anything else still disturb HDMI? (Verified Fact)

| Component | Will it load/bind? | Can it disturb CBoot's HDMI scanout or `simpledrm`? | Evidence (`file:line`) |
| :--- | :--- | :--- | :--- |
| **`host1x`** (`host1x.ko`) | **Yes** — binds to `/host1x@50000000` and `/mipi@700e3000` | **No (Safe).** | `host1x_probe()` (`vendor/linux/drivers/gpu/host1x/dev.c:523-660`) attaches only `TEGRA_SWGROUP_HC` (not `DC`) to the SMMU (`dev.c:456-487`), calls `pm_runtime_resume_and_get()` (`dev.c:640`) which enables `TEGRA210_CLK_HOST1X` and deasserts `mc`/`host1x` resets (`dev.c:733-760`), and **never** runtime-suspends (`dev.c:639`: `/* the driver's code isn't ready yet for the dynamic RPM */`). `tegra_mipi_probe()` (`drivers/gpu/host1x/tegra114-mipi.c:443-475`) only calls `devm_clk_get_prepared()` on `mipi_cal` and never enables runtime PM (`pd_sor` was also deleted in `kernel/dts/darcy.dts:131`). In `drivers/gpu/host1x/bus.c:364-367`, the composite `drm` device is never instantiated unless all subdevs (`dc@54200000`, `dc@54240000`, `vic`, `nvdec`, `nvenc`, `nvjpg`) register, which never happens when `tegra_drm` is blacklisted. |
| **`nouveau`** (`nouveau.ko`) | **No** — `gpu@57000000` is disabled in DT | **No (Safe).** | `gpu@57000000` (`compatible = "nvidia,gm20b"`) has `status = "disabled"` in `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:440-457` and is not enabled in `tegra210-p2894.dtsi` or `darcy.dts`. Even if enabled, `nouveau_platform_device_create()` (`drivers/gpu/drm/nouveau/nouveau_drm.c:1448-1477`) does not call `aperture_remove_conflicting_*` (only PCI `nouveau_drm_probe()` at `nouveau_drm.c:845` does). |
| **`snd-hda-tegra`** (`snd-hda-tegra.ko`) | **No** — `hda@70030000` is disabled in DT | **No (Safe).** | `hda@70030000` has `status = "disabled"` in `tegra210.dtsi:1062-1077` and is not enabled in `tegra210-p2894.dtsi` or `darcy.dts` (and `darcy.dts:132-134` already deleted its `power-domains = <&pd_sor>`). |
| **VT / fbcon blanking** | Built-in | **No (Safe).** | `kernel/dts/darcy-system.dts:24` passes `consoleblank=0`, disabling the kernel VT blanking timer (`drivers/tty/vt/vt.c`). |
| **`clk_ignore_unused` / `pd_ignore_unused`** | Kernel late initcalls | **No (Safe).** | `darcy-system.dts:24` includes `clk_ignore_unused`, `darcy.dts:131` deletes `sor@11` from `pmc@7000e400/powergates`, and with `tegra_drm` blacklisted nothing calls `tegra_pmc_powergate_power_off(TEGRA_POWERGATE_DIS)`. |

- **Defense-in-depth recommendation:** In addition to `module_blacklist=tegra_drm` in `bootargs`, either disable `CONFIG_DRM_TEGRA` in `kernel/darcy.config` or mark `/host1x@50000000/dc@54200000` and `/host1x@50000000/dc@54240000` as `status = "disabled";` in `kernel/dts/darcy.dts`. Disabling the two `dc` DT nodes prevents `54200000.dc` from even emitting a modalias uevent or binding if someone runs `insmod` manually.

---

## (b) Why did Boot 2 (`root=/dev/sda1`, no USB disk) stay on and never reboot to `fastboot`?

Boot 2's behavior is explained by **three verified facts** in the kernel and U-Boot source code (plus one operational timing possibility on the USB cable):

### 1. `root=/dev/sda1 rootwait` (without a timeout) waits forever and NEVER panics (Verified Fact)

In `kernel/dts/darcy-system.dts:24`, the kernel command line contains:
```
root=... rootwait rw panic=10
```
- In `vendor/linux/init/do_mounts.c:64-72`, bare `rootwait` sets `root_wait = -1` (as opposed to `rootwait=N`, which sets `root_wait = N * 1000` ms at `do_mounts.c:74-97`).
- In `prepare_namespace()` (`do_mounts.c:476-483`), `parse_root_device("/dev/sda1")` calls `early_lookup_bdev("/dev/sda1", &dev)` (`do_mounts.c:443`). Because `/dev/sda1` is a syntactically valid path whose device node simply does not exist yet, `early_lookup_bdev()` returns `-ENOENT` (not `-EINVAL`), leaving `ROOT_DEV = 0` and `root_wait = -1`.
- `prepare_namespace()` then calls `wait_for_root("/dev/sda1")` (`do_mounts.c:406-426`):
  ```c
  pr_info("Waiting for root device %s...\n", root_device_name);

  end = ktime_add_ms(ktime_get_raw(), root_wait);

  while (!driver_probe_done() ||
         early_lookup_bdev(root_device_name, &ROOT_DEV) < 0) {
      msleep(5);
      if (root_wait > 0 && ktime_after(ktime_get_raw(), end))
          break;
  }
  ```
- Because `root_wait == -1` (`root_wait > 0` is **false**), **this `while` loop never terminates** when no USB disk is plugged in. The kernel never reaches `mount_root()`, never calls `panic("VFS: Unable to mount root fs...")` (`do_mounts.c:229`), and therefore `panic=10` never fires.
- **Fix for finite root wait:** Pass `rootwait=15` (e.g., 15 seconds) instead of bare `rootwait` in `kernel/dts/darcy-system.dts:24` so that a missing USB disk causes `wait_for_root()` to time out, proceed to `mount_block_root()`, and `panic()` after 15 seconds.

### 2. Even when the kernel DOES panic, U-Boot's `system_payload` path in `p2894.c` ignores `ramoops` and loops forever! (Verified Fact — Bug in `p2894.c`)

Look at `board_late_init()` in `vendor/lineage-u-boot/board/nvidia/p2894/p2894.c:395-430`:
```c
if (system_payload) {
    writel(scratch0 & ~PMC_SCRATCH0_BOOT_RECOVERY,
           NV_PA_PMC_BASE + PMC_SCRATCH0);
    if ((scratch0 & PMC_SCRATCH0_FASTBOOT_FLAG) ||
        probe_host_attached()) {
        report_last_log();
        memset((void *)RAMOOPS_BASE, 0, RAMOOPS_SIZE);
        return 0;
    }
    boot_payload();
    return 0;
}
```
Trace what happens when `system_payload` (`boot-uboot-darcy-system.img` in `boot`) boots Linux and Linux panics and resets (`panic=10`):
1. Before booting Linux, `p2894.c:401-402` cleared `PMC_SCRATCH0_BOOT_RECOVERY` (bit 1).
2. When Linux panics and resets via PSCI `SYSTEM_RESET`, **nothing sets `PMC_SCRATCH0_FASTBOOT_FLAG` (bit 30)** in `PMC_SCRATCH0`.
3. On reboot, CBoot sees bit 1 is 0 and loads `boot` (`boot-uboot-darcy-system.img`).
4. U-Boot enters `if (system_payload)` (`p2894.c:395`). Notice that **`dump_recorded()` is NOT checked inside `if (system_payload)`!** (The `dump_recorded()` check is at line 419, in the probe-only branch *after* `if (system_payload)` has already returned!)
5. Therefore, if no USB host is attached to Port 0 (`probe_host_attached() == false`), `system_payload` U-Boot **never stops in `fastboot` on a panic** — it calls `boot_payload()` again in an infinite crash-reboot loop!

### 3. `struct ramoops_layout` in `p2894.c` does NOT match the kernel's actual `ramoops` memory layout! (Verified Fact — Bug in `p2894.c`)

Even if `dump_recorded()` were called in `if (system_payload)`, **both `dump_recorded()` and `report_last_log()` in `p2894.c` look at the wrong physical addresses**:

In `kernel/dts/darcy-system.dts:26-34` (and `kernel/dts/darcy.dts:33-41`):
```dts
ramoops@deae0000 {
    compatible = "ramoops";
    reg = <0x0 0xdeae0000 0x0 0x100000>; /* size         = 0x100000 (1 MiB)   */
    record-size = <0x80000>;             /* record_size  = 0x080000 (512 KiB) */
    console-size = <0x40000>;            /* console_size = 0x040000 (256 KiB) */
    ftrace-size = <0x20000>;             /* ftrace_size  = 0x020000 (128 KiB) */
    pmsg-size = <0x10000>;               /* pmsg_size    = 0x010000 (64 KiB)  */
    max-reason = <1>;                    /* KMSG_DUMP_PANIC (1)               */
};
```
Now trace `ramoops_probe()` in `vendor/linux/fs/pstore/ram.c:784-813`:
1. `dump_mem_sz = cxt->size - cxt->console_size - cxt->ftrace_size - cxt->pmsg_size` (`ram.c:786-787`)
   `= 0x100000 - 0x40000 - 0x20000 - 0x10000 = 0x90000` (576 KiB).
2. `ramoops_init_przs("dmesg", ..., dump_mem_sz = 0x90000, record_size = 0x80000, &cxt->max_dump_cnt, ...)` (`ram.c:788-790`):
   - At `ram.c:518`: `*cnt = mem_sz / record_size = 0x90000 / 0x80000 = 1` (`max_dump_cnt = 1`).
   - At `ram.c:534`: **`zone_sz = mem_sz / *cnt = 0x90000 / 1 = 0x90000`**!
   - At `ram.c:571`: `*paddr += zone_sz` advances `paddr` by **`0x90000`** (to `0xdeb70000`), **not** `0x80000` (`0xdeb60000`)!
3. Next, `ramoops_init_prz("console", ..., 0x40000)` (`ram.c:794-795`) places `cprz` (`console`) at **`0xdeb70000`** (`+0x90000`).
4. Next, `ramoops_init_prz("pmsg", ..., 0x10000)` (`ram.c:799-800`) places `mprz` (`pmsg`) at **`0xdebb0000`** (`+0xd0000`).
5. Next, `ramoops_init_przs("ftrace", ..., 0x20000, -1, ...)` (`ram.c:804-811`, with `flags = 0` so `max_ftrace_cnt = 1`) places `fprzs[0]` (`ftrace`) at **`0xdebc0000`** (`+0xe0000`..`+0x100000`).
6. When the kernel panics (`KMSG_DUMP_PANIC == 1 <= max_reason`), `ramoops_pstore_write()` (`ram.c:369-392`) writes the panic dump to `cxt->dprzs[0]` at **`0xdeae0000` (`+0x00000`)**!

Compare the kernel's actual layout with `struct ramoops_layout` in `vendor/lineage-u-boot/board/nvidia/p2894/p2894.c:48-63`:

| Zone | Actual Kernel Offset (`fs/pstore/ram.c`) | Actual Size | `p2894.c` `struct ramoops_layout` Offset | `p2894.c` Assumed Size | Consequence in `p2894.c` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`dmesg` (`dprzs[0]`, panic dump)** | `+0x00000` (`0xdeae0000`) | `0x90000` | `+0x00000` (`ramoops->dmesg`) | `0x80000` | Kernel writes panic dumps here (`+0x00000`), **not** at `+0xef000`. |
| **`console` (`cprz`)** | **`+0x90000` (`0xdeb70000`)** | `0x40000` | **`+0x80000` (`0xdeb60000`)** | `0x40000` | `report_last_log()` (`p2894.c:89`) reads `+0x80000` (inside `dmesg`), never finding `PERSISTENT_RAM_SIG`, so **`last-log` is never reported**! |
| **`pmsg` (`mprz`)** | `+0xd0000` (`0xdebb0000`) | `0x10000` | `+0xc0000` (`0xdeba0000`) | `0x10000` | Shifted by `0x10000`. |
| **`ftrace` (`fprzs[0]`)** | `+0xe0000` (`0xdebc0000`) | `0x20000` | `+0xd0000` (`0xdebb0000`) | `4 * 0x7c00` | Shifted by `0x10000`. |
| **`dump` (non-existent)** | *Does not exist* | — | **`+0xef000` (`0xdebcf000`)** | `0x11000` | `dump_recorded()` (`p2894.c:60-63`) checks `prz_valid(&ramoops->dump, 0x11000)` at `+0xef000` (inside `ftrace`), which is **always `0`**! |

**How to fix both `ramoops` issues:**
- Either set `record-size = <0x90000>;` (Wait: `ram.c:765-766` rounds `record_size` down to a power of two: `rounddown_pow_of_two(0x90000) == 0x80000`!) Because `ram.c:765-772` forces `record_size`, `console_size`, `ftrace_size`, and `pmsg_size` to be powers of two, `0x80000 + 0x40000 + 0x20000 + 0x10000 = 0xf0000` always leaves `0x90000` for `dump_mem_sz` when `reg` is `0x100000`!
- Therefore, in `p2894.c`:
  1. `dmesg` (the panic dump zone `dprzs[0]`) is at `+0x00000` with size `0x90000` (`u8 data[0x90000 - 12]`),
  2. `console` is at `+0x90000` with size `0x40000`,
  3. `dump_recorded()` must check `prz_valid(&ramoops->dmesg, 0x90000)` (at `+0x00000`), and
  4. `if (system_payload)` (`p2894.c:395-407`) must also check `|| dump_recorded()` so a kernel panic in installed-system mode stops in `fastboot` and exposes `fastboot getvar last-log` instead of boot-looping!

### 4. Why Boot 2 showed no HDMI signal (Plausible Inference from Verified Code)

In Boot 2 (`NOTES.md:947-955`), there are two ways HDMI stayed dark:
1. **If the USB cable was unplugged more than ~1 second after `fastboot reboot`:** CBoot + U-Boot reach `board_late_init()` (`p2894.c:383`) in ~1 second. If the host cable was still attached at that instant, `probe_host_attached()` returned `true`, `board_late_init()` returned `0` to `preboot`, and U-Boot entered `fastboot usb 0` (`p2894.env:9`). Once inside `fastboot usb 0`, unplugging the USB cable does **not** exit `fastboot` — U-Boot stays in the `fastboot` command loop indefinitely (which does not render to the HDMI framebuffer).
2. **If the USB cable was unplugged before `board_late_init()`:** U-Boot booted Linux, and Linux hung silently in `wait_for_root("/dev/sda1")` (Section b.1 above).

---

## (c) What will happen when `brcmfmac` + `iwd` try to join the Wi-Fi network on first boot?

With the current `build/linux/.config` and `build/rootfs.img`, **Wi-Fi will fail on first boot for two independent, verified reasons** before a single 802.11 frame is transmitted:

### 1. Blocker 1: `CONFIG_BRCMFMAC=y` (built-in) + no initramfs + slow USB rootfs causes `brcmfmac` to fail firmware load at early boot and permanently unbind itself! (Verified Fact)

- In the probe image (`boot-uboot-darcy.img`), the FIT image included an `initramfs`. In the kernel boot sequence (`vendor/linux/init/main.c:1417, 1676`), `populate_rootfs()` (`rootfs_initcall`, level `5s`) unpacks the initramfs **before** `device_initcall` (level `6`), so `/lib/firmware/brcm/brcmfmac4354-sdio.bin` was already present in RAM when `brcmfmac` probed at level `6`.
- In the installed-system image (`boot-uboot-darcy-system.img`), **there is no initramfs** (`scripts/12-make-payload.sh:81-116`). The USB root filesystem (`root=PARTLABEL=darcy-root`) is not mounted until `prepare_namespace()` (`vendor/linux/init/do_mounts.c:457-483`), which runs **after** all `do_initcalls()` complete and after waiting ~1.5–3 seconds for USB3 disk enumeration in `wait_for_root()`.
- Because `CONFIG_MMC_SDHCI_TEGRA=y` and `CONFIG_BRCMFMAC=y` are built-in (`kernel/darcy.config:6-7`), `mmc1` (`mmc@700b0200`) enumerates the SDIO BCM4354 (`mmc1:0001:1` and `mmc1:0001:2`) during `do_initcalls()` (~150 ms into boot) and `brcmf_sdio_probe()` (`vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/sdio.c:4450-4530`) immediately schedules `request_firmware_nowait()` (`brcmfmac/firmware.c:756-800`) on `system_wq`.
- That workqueue item runs **while `/` is still the empty in-RAM `rootfs`** (while `wait_for_root()` is still waiting for `/dev/sda1`).
- In `build/linux/.config`, `# CONFIG_FW_LOADER_USER_HELPER_FALLBACK is not set`. Thus `_request_firmware()` (`vendor/linux/drivers/base/firmware_loader/main.c:873-900`) immediately fails with `-ENOENT`.
- When `brcmf_sdio_firmware_callback()` (`brcmfmac/sdio.c:4260-4422`) receives `err = -ENOENT`, it jumps to `fail:` (`sdio.c:4418-4422`):
  ```c
  device_release_driver(&sdiod->func2->dev);
  device_release_driver(dev);
  ```
  This unbinds `brcmfmac` from `mmc1:0001:1` and `mmc1:0001:2`.
- Later, when `systemd-udevd` runs `udevadm trigger --type=devices --action=add`, writing `"add"` to `/sys/bus/sdio/devices/mmc1:0001:1/uevent` only emits a `KOBJ_ADD` uevent to userspace; `udev`'s builtin `kmod` sees `brcmfmac` in `/lib/modules/7.2.11-ga2de78ee6ed8/modules.builtin` (`KMOD_MODULE_BUILTIN`) and does nothing. **`wlan0` is never created!**
- **Fix:** Either change `CONFIG_BRCMFMAC=m` (so `systemd-udevd` loads `brcmfmac.ko` from the mounted USB rootfs *after* `/lib/firmware` is available), or build the BCM4354 firmware/NVRAM/CLM into the kernel image via `CONFIG_EXTRA_FIRMWARE`.

### 2. Blocker 2: `iwd` will immediately exit with `EXIT_FAILURE` on startup because `CONFIG_CRYPTO_USER_API_HASH` and `CONFIG_CRYPTO_USER_API_SKCIPHER` are disabled in `build/linux/.config`! (Verified Fact)

Even if `wlan0` were present, `iwd` (via `libell`) performs all user-space hashing, HMAC, CMAC, and symmetric encryption through Linux `AF_ALG` sockets (`algif_hash` and `algif_skcipher`), and runs `check_crypto()` at the start of `main()` before doing anything else.

Inspecting `build/linux/.config` alongside the `check_crypto()` string table in `/usr/lib/iwd/iwd` inside `build/rootfs.img` shows:

| Kernel Option Required/Checked by `iwd` | Status in `build/linux/.config` | Impact on `iwd` Startup (`check_crypto()`) |
| :--- | :--- | :--- |
| **`CONFIG_CRYPTO_USER_API_HASH`** (`algif_hash`) | **`is not set`** | **FATAL:** `No HMAC(SHA1)`, `No HMAC(MD5)`, `No CMAC(AES)`, `No HMAC(SHA256)` — `iwd` refuses to start (`EXIT_FAILURE`). |
| **`CONFIG_CRYPTO_USER_API_SKCIPHER`** (`algif_skcipher`) | **`is not set`** | **FATAL:** `DES support not found`, `AES support not found` — `iwd` refuses to start (`EXIT_FAILURE`). |
| **`CONFIG_CRYPTO_MD5`** / **`CONFIG_CRYPTO_DES`** | `=m` (`md5.ko`, `des_generic.ko`) | **FATAL if modules cannot autoload** (required by `check_crypto()` even for WPA2-PSK networks). Making them `=y` avoids any module dependency. |
| `CONFIG_CRYPTO_SHA1`, `SHA256`, `SHA512`, `HMAC`, `CMAC`, `AES`, `ECB`, `CBC` | `=y` | Present in kernel, but unreachable from `iwd` without `CONFIG_CRYPTO_USER_API_HASH=y` and `CONFIG_CRYPTO_USER_API_SKCIPHER=y`. |
| `CONFIG_KEY_DH_OPERATIONS` | `is not set` | Non-fatal warning (`No Diffie-Hellman support found, WPS will not be available`). |
| `CONFIG_PKCS8_PRIVATE_KEY_PARSER` | `is not set` | Non-fatal warning for EAP/TLS (`WPA-Enterprise`). |

- **Fix:** Add to `kernel/darcy.config`:
  ```ini
  CONFIG_CRYPTO_USER_API_HASH=y
  CONFIG_CRYPTO_USER_API_SKCIPHER=y
  CONFIG_CRYPTO_MD5=y
  CONFIG_CRYPTO_DES=y
  CONFIG_KEY_DH_OPERATIONS=y
  CONFIG_PKCS8_PRIVATE_KEY_PARSER=y
  ```

### 3. WPA2-PSK vs. WPA3-SAE on BCM4354 (`7.35.349.111`) once Blockers 1 & 2 are fixed (Verified Fact)

Inspecting `/usr/lib/firmware/brcm/brcmfmac4354-sdio.nvidia,p2894-0050-a08.bin` in `build/rootfs.img` shows the firmware banner:
```
4354a1-roml/sdio-ag-p2p-pno-aoe-pktfilter-keepalive-sr-mchan-pktctx-proptxstatus-lpc-pwropt-txbf-wl11u-mfp-tdls-nvd-dfsago-atv-noclminc-clm_min Version: 7.35.349.111 (8083386 CY) CRC: c3f8a310 Date: Mon 2021-08-16 23:40:51 PDT Ucode Ver: 986.1213 FWID 01-d3fd04f1
```
- **Firmware capabilities (`vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/feature.c:37-48`, `cfg80211.c:7676-7712`):**
  - The firmware capability string contains `mfp` (`BRCMF_FEAT_MFP`), so `brcmfmac` advertises `WLAN_CIPHER_SUITE_AES_CMAC` (802.11w PMF/MFP).
  - It does **not** contain `sae `, `sae_ext`, or `sup_wpa` (`BRCMF_FEAT_FWSUP`). Thus neither `NL80211_EXT_FEATURE_SAE_OFFLOAD` nor `NL80211_FEATURE_SAE` is advertised on `wiphy`.
  - Because `brcmfmac` is a FullMAC driver using `NL80211_CMD_CONNECT` (rather than softMAC `NL80211_CMD_AUTHENTICATE`), **WPA3-SAE-only networks cannot be joined** with this BCM4354 firmware.
  - **WPA2-PSK (and WPA2/WPA3-Transition mode APs):** `iwd` will see that SAE is not supported by the `wiphy`, select `WPA2-PSK` (`AKM 00-0f-ac:2` or `00-0f-ac:6` with MFP), call `NL80211_CMD_CONNECT`, complete the 4-way EAPOL handshake in userspace via `AF_ALG`, install the keys via `NL80211_CMD_NEW_KEY`, and `systemd-networkd` (`25-wlan.network`) will acquire a DHCP lease on `wlan0`.

### 4. Kernel module `vermagic` alignment (Verified Fact)

- `build/linux/include/generated/utsrelease.h:1` defines `UTS_RELEASE "7.2.11-ga2de78ee6ed8"`, and `build/rootfs.img` has `/usr/lib/modules/7.2.11-ga2de78ee6ed8`.
- In `build/linux/.config`, `CONFIG_LOCALVERSION_AUTO=y` and `# CONFIG_MODVERSIONS is not set`.
- By `vendor/linux/include/linux/vermagic.h:41-46`, the vermagic string is `"7.2.11-ga2de78ee6ed8 SMP preempt mod_unload aarch64"`.
- **Caution when rebuilding the kernel (`scripts/11-build-kernel.sh`):** Because `vendor/linux` is a git repo at `a2de78ee6ed8`, as long as `vendor/linux` stays clean (all config changes are in `kernel/darcy.config`), `UTS_RELEASE` remains `7.2.11-ga2de78ee6ed8`. However, if you change `CONFIG_BRCMFMAC=m` (producing a new `brcmfmac.ko`), you **must** also install the new `.ko` modules onto the USB disk (not just `--boot-only`), otherwise `brcmfmac.ko` will not exist in `/lib/modules/7.2.11-ga2de78ee6ed8/` on the USB disk!

---

## (d) How hard is it to bring up the OTG port (`usb2-0`) in device mode under Linux (`tegra-xudc`)?

**It is very easy (~25 lines of DT + 2 built-in Kconfig options or module load), and all drivers are already compiled in `build/linux`!**

### 1. Current state in `build/linux` and `tegra210-p2894.dtsi` (Verified Fact)

- **Kernel drivers already built (`build/linux/.config`):**
  - `CONFIG_USB_GADGET=y`
  - `CONFIG_USB_ROLE_SWITCH=y`
  - `CONFIG_USB_CONN_GPIO=y` (`drivers/usb/common/usb-conn-gpio.c`)
  - `CONFIG_USB_TEGRA_PHY=y`
  - `CONFIG_USB_TEGRA_XUDC=m` (`drivers/usb/gadget/udc/tegra-xudc.ko`)
  - `CONFIG_USB_CONFIGFS=m`, `CONFIG_USB_CONFIGFS_ACM=y`, `CONFIG_USB_CONFIGFS_SERIAL=y`, `CONFIG_USB_CONFIGFS_NCM=y`, `CONFIG_USB_CONFIGFS_ECM=y`, `CONFIG_USB_CONFIGFS_RNDIS=y` (`usb_f_acm.ko`, `usb_f_ncm.ko`, etc.)
- **What is currently in `vendor/linux/arch/arm64/boot/dts/nvidia/tegra210-p2894.dtsi`:**
  - `padctl@7009f000/ports/usb2-0` (`tegra210-p2894.dtsi:1580-1584`) currently has `mode = "host"; vbus-supply = <&vdd_usb_vbus1>;`.
  - `usb@700d0000` (`compatible = "nvidia,tegra210-xudc"` in `tegra210.dtsi:1370-1387`) has `status = "disabled";` and is never enabled in `tegra210-p2894.dtsi` or `kernel/dts/darcy.dts`.

### 2. How `tegra-xusb-padctl` and `tegra-xudc` coordinate Device Mode in Linux 7.2 (Verified Fact)

1. In `vendor/linux/drivers/phy/tegra/xusb.c:765-779`, when `padctl@7009f000/ports/usb2-0` has `mode = "otg"` (or `"peripheral"`) and `usb-role-switch;`, `tegra_xusb_setup_usb_role_switch()` (`xusb.c:660-725`) registers a `usb_role_switch` (`/sys/class/usb_role/usb2-0-role-switch/role`) with `.allow_userspace_control = true` and calls `tegra_xusb_parse_usb_role_default_mode()` (`xusb.c:727-741`), which reads `role-switch-default-mode = "peripheral"` (or `"host"`).
2. When the role switch transitions to `USB_ROLE_DEVICE` (either at boot via `role-switch-default-mode = "peripheral"`, via a `gpio-usb-b-connector` child node, or at runtime by writing `device` to `/sys/class/usb_role/usb2-0-role-switch/role`), `tegra_xusb_usb_phy_work()` (`xusb.c:607-620`) sets `port->usb_phy.last_event = USB_EVENT_VBUS` and fires `port->usb_phy.notifier`.
3. In `vendor/linux/drivers/usb/gadget/udc/tegra-xudc.c:3517-3569, 3895-3901`, `tegra_xudc_probe()` looks up `phy-names = "usb2-0", "usb3-0"` (pairing `usb2-0` with `usb3-0` via `nvidia,usb2-companion = <0>`), registers `xudc->vbus_nb` on `xudc->usbphy[0]`, and calls `tegra_xudc_update_data_role()` (`tegra-xudc.c:803-827`).
4. Seeing `USB_EVENT_VBUS`, `tegra-xudc` runs `tegra_xudc_device_mode_on()` (`tegra-xudc.c:699-721`), which powers on the UTMI and USB3 PHYs and calls `phy_set_mode_ext(xudc->curr_utmi_phy, PHY_MODE_USB_OTG, USB_ROLE_DEVICE)` -> `tegra210_xusb_padctl_vbus_override(padctl, true)` (`drivers/phy/tegra/xusb-tegra210.c:1931-1932`).

### 3. Exact DT + Kconfig additions needed for Darcy (`p2894`) (Verified Fact from Downstream + Mainline DTs)

From `vendor/lineage-t210-foster/kernel-dts/tegra210-darcy-p2894-common.dtsi:221-284` and `foster-platforms/tegra210-darcy-power-tree-p2894-0000-a00.dtsi:322-332`, the exact DT additions in `kernel/dts/darcy.dts` are:
```dts
/ {
	padctl@7009f000 {
		ports {
			usb2-0 {
				mode = "otg";
				usb-role-switch;
				role-switch-default-mode = "peripheral";
			};
		};
	};

	usb@700d0000 {
		phys = <&{/padctl@7009f000/pads/usb2/lanes/usb2-0}>,
		       <&{/padctl@7009f000/pads/pcie/lanes/pcie-6}>;
		phy-names = "usb2-0", "usb3-0";
		avddio-usb-supply = <&max77620_ldo1>;
		hvdd-usb-supply = <&vdd_3v3_sys>;
		status = "okay";
	};
};
```
*(Note on `role-switch-default-mode = "peripheral"` vs `gpio-usb-b-connector`: On Darcy, Port 0 is a USB Type-A receptacle with no physical ID pin (`id_extcon: virtual_id` in `tegra210-darcy-extcon-p2894-0000-a00.dtsi:18-26`), and the USB disk + Ethernet adapter are on Port 2 (`usb2-2`/`usb3-1` internal hub). Setting `role-switch-default-mode = "peripheral"` on `usb2-0` puts Port 0 unconditionally into Device mode for host A-to-A connection without needing any GPIO cable detection, while still allowing runtime switching via `/sys/class/usb_role/usb2-0-role-switch/role`.)*

If you also set in `kernel/darcy.config`:
```ini
CONFIG_USB_TEGRA_XUDC=y
CONFIG_USB_G_ACM_MS=y   # or CONFIG_USB_ETH=y / CONFIG_USB_G_SERIAL=y (with g_serial.use_acm=1)
```
and add `console=ttyGS0` to `bootargs` (plus `systemctl enable serial-getty@ttyGS0.service`), the host PC plugged into Port 0 gets an **immediate `/dev/ttyACM0` kernel console and root login prompt over the existing USB A-to-A cable** with zero userspace ConfigFS setup required!

---

## (e) What would you do before or instead of Boot 4?

**Do NOT run Boot 4 with the current image yet.** As proven in Sections (b) and (c), Boot 4 with only `module_blacklist=tegra_drm` would keep HDMI alive (`simpledrm`), **but Wi-Fi would still fail completely** (because `CONFIG_BRCMFMAC=y` fails firmware load before the USB disk is mounted and unbinds itself, and `iwd` exits immediately because `CONFIG_CRYPTO_USER_API_HASH` and `CONFIG_CRYPTO_USER_API_SKCIPHER` are unset), and if the USB rootfs ever failed to mount, `rootwait` + `p2894.c` would still hang instead of falling back to `fastboot`.

Instead, do one combined rebuild before Boot 4 that fixes all four issues at once:

1. **Fix `p2894.c` panic/ramoops handling (`vendor/lineage-u-boot/board/nvidia/p2894/p2894.c`):**
   - Fix `struct ramoops_layout` (`p2894.c:48-55`) so `dmesg` is `0x90000` bytes (`u8 data[0x90000 - 12]`) at `+0x00000` and `console` is at `+0x90000` (`0xdeb70000`).
   - Change `dump_recorded()` (`p2894.c:60-63`) to check `prz_valid(&ramoops->dmesg, 0x90000)`.
   - In `board_late_init()` (`p2894.c:403-404`), add `|| dump_recorded()` to the `if (system_payload)` condition so a kernel panic in installed-system mode stops in `fastboot` and exposes `fastboot getvar last-log`.
2. **Fix `darcy-system.dts` bootargs (`kernel/dts/darcy-system.dts:24`):**
   - Keep `module_blacklist=tegra_drm`.
   - Change bare `rootwait` to `rootwait=15` so a missing/unreadable USB disk actually triggers `panic("VFS: Unable to mount root fs...")` after 15 seconds instead of looping forever in `wait_for_root()`.
3. **Fix Wi-Fi + `iwd` in `kernel/darcy.config`:**
   - Either change `CONFIG_BRCMFMAC=m` (or embed firmware via `CONFIG_EXTRA_FIRMWARE`) so `brcmfmac` probes *after* `/lib/firmware` on the USB disk is mounted.
   - Add `CONFIG_CRYPTO_USER_API_HASH=y`, `CONFIG_CRYPTO_USER_API_SKCIPHER=y`, `CONFIG_CRYPTO_MD5=y`, `CONFIG_CRYPTO_DES=y`, `CONFIG_KEY_DH_OPERATIONS=y`, and `CONFIG_PKCS8_PRIVATE_KEY_PARSER=y` so `iwd`'s `check_crypto()` succeeds.
4. **Enable USB OTG serial console (`ttyGS0`) as an out-of-band diagnostic channel (Section d):**
   - Add the `usb@700d0000` and `usb2-0` (`mode = "otg"; usb-role-switch; role-switch-default-mode = "peripheral";`) nodes to `kernel/dts/darcy.dts`, and enable `CONFIG_USB_TEGRA_XUDC=y` + `CONFIG_USB_G_SERIAL=y` with `console=ttyGS0` in `darcy-system.dts`. That gives you a live kernel log + root login on `/dev/ttyACM0` over the USB A-to-A cable independent of both HDMI and Wi-Fi.
5. **Sync modules to the USB disk if any `=m` options changed:**
   - If you change `CONFIG_BRCMFMAC=m` (or any other `=m` option), copy the updated `/usr/lib/modules/7.2.11-ga2de78ee6ed8` tree onto the USB disk (`darcy-root`) before booting.
