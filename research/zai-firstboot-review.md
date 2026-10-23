# Review: first boots of the installed system on the SHIELD TV 2017 (darcy)

**Verdict up front.** Two real bugs in the plan, both cheap to fix, and one
mechanism in NOTES that does not survive a code read:

1. **`module_blacklist=tegra_drm` is a no-op as spelled.** The kernel
   blacklist matches module names with an exact `memcmp` — no `_`/`-`
   normalization (`kernel/module/main.c:2936-2951`, applied at
   `main.c:3404-3407` even for userspace modprobe) — and the module is
   `tegra-drm.ko` (dash; `drivers/gpu/drm/tegra/Makefile:35`, and
   `build/linux/drivers/gpu/drm/tegra/tegra-drm.ko` exists). It must be
   `module_blacklist=tegra-drm`.
2. **tegra-drm almost certainly did not remove the framebuffer in boots
   1/3**, because the aperture call is guarded by `num_crtc > 0`
   (`drivers/gpu/drm/tegra/drm.c:1259-1261`) and the DT has every display
   node disabled — the journal's own `Cannot find any crtc or sizes`
   (`drm_fb_helper.c:1485-1488`, `crtc_count == 0`) proves no CRTC existed.
   So blacklisting tegra-drm is right hygiene, but be prepared for the
   picture to still die at ~3 s; the real killer is unidentified (§a).
3. The panic route to fastboot is **sound** (§b), with one timing caveat
   (the still-armed watchdog bounds the fastboot window) and one already-
   correct detail worth confirming (max-reason = <1>).
4. The crypto list is essentially complete; two nits: `CRYPTO_USER_API`
   gets promoted to `=y` automatically (HASH/SKCIPHER `select` it — no
   extra line needed), and `CRYPTO_USER_API_ENABLE_OBSOLETE=y` is already
   set and must stay (md5/des via AF_ALG need it). No SAE/AES-CE gaps (§c).
5. A USB gadget console is very tractable on this board — the far port's
   device mode is already proven by cboot's fastboot on the same XUDC
   hardware (§d).

All paths relative to `~/projects/nvidia`; `vendor/linux` = 7.2.11.

---

## a) Display: is `module_blacklist` right and sufficient?

**The spelling bug, precisely.** `blacklisted()` compares
`strlen(module_name) == len && !memcmp(module_name, p, len)`
(`kernel/module/main.c:2944-2949`); `info->name` for our module is
`tegra-drm` (from `tegra-drm.o` in the Makefile). `tegra_drm` never
matches, `load_module()` refuses nothing, udev's modprobe succeeds exactly
as before. The check at `main.c:3404-3407` does cover the
`finit_module()` path, so with the dash form the blacklist blocks udev too
— it is the right mechanism, just the wrong string. Use
`module_blacklist=tegra-drm` (adding both spellings is harmless).

**But the eviction story in NOTES/`fd5f1a9` doesn't hold.** With
`dc@54200000`, `dc@54240000`, `sor0`, `sor1`, `dpaux`, `dpaux1` all
`status = "disabled"` (`tegra210.dtsi:192-208, 316-355, 108-119`, and
`darcy.dts` enables none of them), tegra-drm loads with **zero CRTCs** —
indeed that is exactly what the journal reports — and
`host1x_drm_probe()` then *skips*
`aperture_remove_all_conflicting_devices()` (`drm.c:1259-1261`:
`if (drm->mode_config.num_crtc > 0)`), clears MODESET features instead,
and its fbdev client prints `Cannot find any crtc or sizes`
(`drm_fb_helper.c:1487`). simpledrm should have survived tegra-drm. Why
tegra-drm loads at all: its aliases come from the *enabled* host1x
children `vic@54340000`/`nvdec`/`nvenc`/`nvjpg`/`tsec`
(`tegra210.dtsi:240-307`, no status property → okay), whose drivers live
in `tegra-drm.ko`; note `host1x@50000000` itself is also enabled, so
`host1x.ko` loads too.

**Verified non-evictors in a normal systemd boot:**

- **nouveau**: won't even load — `gpu@57000000` is `status = "disabled"`
  (`tegra210.dtsi:440-457`), so no modalias. And even if enabled, the
  Tegra platform probe has no aperture call (`nouveau_platform.c:26-36`;
  the only one is `aperture_remove_conflicting_pci_devices` in the PCI
  probe, `nouveau_drm.c:877`).
- **host1x.ko**: no aperture calls anywhere in `drivers/gpu/host1x`; its
  probe writes only host1x-internal state (own clock, syncpts, IRQs) and
  deasserts a reset that is already deasserted.
- **snd-hda-tegra**: `hda@70030000` is disabled (`darcy.dts` only strips
  its `power-domains`), so the module never loads.
- **simpledrm** never unregisters itself, and no other module in
  `darcy.config`/defconfig calls `remove_conflicting_framebuffers`.
- Console blanking: `consoleblank=0` is set; systemd/logind doesn't blank
  VTs by default; `agetty` clears the screen but shows a prompt.

**What I'd do:** flash the blacklist (spelled correctly) — it removes the
only DRM driver this DT can autoload — but treat the next boot as a
diagnostic, not a fix: if the TV still dies at ~3 s, the cause was never
tegra-drm. Evidence to collect then: (1) the TV's own OSD — "No signal"
(TMDS died again, display-silicon cause) vs a black-but-lit picture
(console/fb path); (2) from the SSD, `journalctl -k -b X | grep -Ei
'fb0|fbcon|switch|host1x|simpledrm|drm|watchdog'` around the death
timestamp, plus any line mentioning `fb0: switching` or device removal.
The SSD journal channel you already used is the right tool; nothing else
needs building for it.

## b) The SSD-less panic route into fastboot

Walked the whole chain in the patch and DT; it is sound:

- Kernel: `root=PARTLABEL=darcy-root rootwait=30` (darcy-system.dts:24) →
  "VFS: Cannot open root device" panic after ~31 s; `panic=10` resets.
- Panic record: `max-reason = <1>` (darcy-system.dts:36) = `KMSG_DUMP_PANIC`
  only — the value is right, and also right to exclude oopses (an oops
  with a still-running reboot would otherwise masquerade as a panic).
  `CONFIG_PSTORE_RAM=y` writes one dump record into the zone layout
  `ramoops_layout()` parses (it reads sizes from the FIT's DT, so the
  writer and reader agree). The panic path runs `kmsg_dump` before the
  reset; a PSCI warm reset preserves RAM (proven by every earlier
  recovery-loop log, which used the same reset type).
- U-Boot: `nvidia_board_late_init()` finds the FIT via cboot's ramdisk,
  sees `/chosen/darcy,system`, and takes the log branch when
  `dump_recorded()` is true (`patch` lines ~803-815: sig `0x43474244` +
  valid size in any dump record — matches `PERSISTENT_RAM_SIG`). The
  console zone carries the `darcy.chain=u-boot` tag from `tag_bootargs()`
  (proven mechanism from the test loop). Then `darcy_log_secs=60` dwell
  and `reboot_to(true)` → bootloader menu → fastboot on the far port.
- Timing: kernel starts ≈ T0 (watchdog armed 150 s at T0-ε); panic at
  ~T0+31 s, reset ~T0+41 s; log shown ≈ T0+55 s, fastboot at ≈T0+115 s —
  comfortably before the watchdog expires at ~T0+150 s.

Two caveats worth knowing, neither blocking:

1. **The fastboot window is bounded by the still-armed watchdog.** Nothing
   in U-Boot's log path or in cboot's menu services WDT0. From the moment
   the kernel was started, ~150 s elapse → roughly 35 s of fastboot before
   an unprompted reset. Flashing `scripts/14` (~12 MB over USB2) fits
   easily; if you dawdle the board resets, and since `report_last_log()`
   zapped the records, the next cycle is: boot → panic (no SSD) → log →
   fastboot again. Annoying loop, never a lockout — but do the flash
   promptly or expect the extra cycle.
2. **The watchdog variant of the policy depends on cboot's exact
   `androidboot.bootreason=watchdog` string** (`watchdog_reset()`, patch
   ~817-829). The panic variant never consults it, so the route you plan
   is the robust one. The hang→watchdog variant remains unverified until
   you see the string once.

**Better ways into fastboot:** none simpler — the panic route needs no
tools and no working display. Two fallbacks that already exist: the
bootloader menu is navigable by USB keyboard in the near port (proven,
NOTES 2026-10-22), and a kernel *hang* still ends in the watchdog path
above. If the panic loop's failure mode ever materializes (log branch
doesn't trigger), you'll see it immediately: U-Boot text every ~50 s on
the TV — visible, not silent — and the keyboard menu is the manual
override.

## c) iwd's kernel options

The proposed set (`USER_API_HASH`, `USER_API_SKCIPHER`, `KEY_DH_OPERATIONS`,
`CRYPTO_MD5`, `CRYPTO_DES`, `PKCS8_PRIVATE_KEY_PARSER` = y) matches iwd's
own startup checklist one-for-one. Details verified:

- **The two real blockers** were `CRYPTO_USER_API_HASH` and
  `CRYPTO_USER_API_SKCIPHER` (`# ... is not set` in `build/linux/.config`)
  — without them iwd cannot bind any AF_ALG hash/skcipher and exits.
  Setting both to `y` also promotes `CRYPTO_USER_API` to `=y`
  automatically: both are `tristate` options that **`select
  CRYPTO_USER_API`** (`crypto/Kconfig:1237-1261`), so no extra line is
  needed for the parent (adding one is harmless).
- **MD5/DES =y** is the deterministic choice; as modules they would also
  autoload (`MODULE_ALIAS_CRYPTO`), but =y removes the ordering
  dependency on udev being up before iwd. Note
  `CONFIG_CRYPTO_USER_API_ENABLE_OBSOLETE=y` is already set — required
  for md5/des over AF_ALG (af_alg refuses "obsolete" algorithms without
  it); keep it.
- **WPA3-Personal/SAE: covered.** SAE needs ECDH over AF_ALG's
  `KEY_DH_OPERATIONS` — `CONFIG_CRYPTO_ECC=y` and `CONFIG_CRYPTO_ECDH=y`
  are already set, and `KEY_DH_OPERATIONS=y` additionally pulls
  `CRYPTO_DH` + `CRYPTO_KDF800108_CTR` (`security/keys/Kconfig:110-113`).
  The P-256 curve (SAE group 19) is in `crypto/ecc.c`. iwd does the
  hash-to-curve hunting-and-pecking in userspace; nothing else kernel-side
  is needed. WPA2-Personal's PBKDF2/HMAC-SHA1 and 802.11w's AES-CMAC map
  to already-=y options (`HMAC`, `SHA1`, `CMAC`, `AES`).
- **AES-CE**: accelerated implementations are already =y
  (`CRYPTO_AES_ARM64_CE_BLK`, `..._CE_CCM`); not on iwd's list, purely
  performance. brcmfmac does the on-air encryption in firmware, so kernel
  crypto is only the supplicant's math.
- **PKCS8_PRIVATE_KEY_PARSER=y**: only silences iwd's `modules-load.d`
  load of `pkcs8_key_parser` (needed for EAP-TLS keys, not PSK); cheap,
  fine.

**MODVERSIONS-off question:** the old modules would *load* — without
`CONFIG_MODVERSIONS` there are no symbol-version checks; `finit_module()`
compares only the vermagic string (release + a few build flags), and a
rebuild of the same tree produces the same "7.2.11" vermagic. But "loads"
is not "safe": with no CRC checks, any layout change in an exported
struct turns into silent corruption instead of a load-time error. Since
the plan already rebuilds the rootfs (`scripts/13`) and rewrites the SSD
(`scripts/15`), keep doing that and always flash the boot FIT
(`scripts/14`) from the *same tree state* as the SSD's `/lib/modules`.
Never mix a new FIT with old modules on the disk.

## d) A display/network-independent debug channel

The far port (OTG) is the ideal gadget port, and its device mode is
**already proven**: cboot's fastboot enumerates as `0955:b442` over the
same XUSB device controller. Linux-side:

- **Config**: everything needed is in `.config` — `USB_TEGRA_XUDC=m`,
  `USB_CONFIGFS=m` with `SERIAL/ACM/NCM/ECM/RNDIS/EEM` function options
  set. That gives either a serial console (`ttyGS0` over CDC-ACM — laptop
  side needs no network config, just `screen /dev/ttyACM0`) or Ethernet
  (ECM/RNDIS → ssh). A `getty@ttyGS0` symlink or a
  `console=ttyGS0,115200` addition makes it a real console.
- **DT** (darcy.dts), modeled on Jetson Nano (`tegra210-p3450-0000.dts:586-
  595`) and Pixel C (`tegra210-smaug.dts:1867-1877`):
  - `&{/usb@700d0000}` (xudc): `status = "okay"`,
    `phys = <&{/padctl@7009f000/pads/usb2/lanes/usb2-0}>`,
    `phy-names = "usb2-0"`, supplies mirroring the host port's
    (`avddio-usb-supply = <&vdd_3v3>`, `hvdd-usb-supply = <&max77620_sd3>`
    — see darcy.dts:199-201). USB2-only is fine for a console.
  - padctl: enable lane `usb2-0` with `nvidia,function = "xusb"`, and
    `ports/usb2-0` with `mode = "device"` (keeping the host port's
    `usb2-2`/`usb3-1` config untouched, darcy.dts:150-203).
  - The xudc node's `power-domains = <&pd_xusbdev>, <&pd_xusbss>`
    (`tegra210.dtsi:1383`) work in our favor: those pd nodes still exist,
    so genpd powers them up properly at probe.
- **Userspace**: one small script (or systemd unit) that builds a configfs
  gadget with function `acm.USBT0` (or `ecm.USBT0` + a MAC) and binds it
  to the `700d0000.xudc` UDC.
- **Effort/risk**: roughly half a day including a test cycle. Main risks:
  the padctl port mode transition on a port cboot used as device (cboot
  leaves it in a fastboot state; `mode = "device"` should re-init it), and
  the gadget's VBUS perception over the A-A cable (the laptop is host and
  supplies VBUS, which is exactly what the XUDC wants). Given the panic
  route (§b) and the SSD journal reads already work, I'd schedule this
  *after* Wi-Fi, not instead of it.

An even cheaper stopgap exists: the SSD is removable —
`journalctl -D <ssd>/var/log/journal` from the laptop is a full log
channel that already produced the boot-1/3 evidence, and `device-info/
ssh` + scripts/13's root-key setup means the moment any network comes up
you're in. The gadget is the *always-works* channel; build it once, keep
it forever.

## e) Order of steps, and risks

Recommended order (each step de-risks the next):

1. **Fix the blacklist spelling** in `kernel/dts/darcy-system.dts`
   (`tegra-drm`, not `tegra_drm`), rebuild the system FIT (scripts/12).
   Without this, the flashed "fix" changes nothing and you'll misread the
   next boot as "blacklist doesn't help".
2. **Prove the panic route with the currently flashed image** — power on
   once without the SSD, watch the log + fastboot, then restore power
   with the SSD reattached. No flashing needed; it validates §b end-to-end
   (dump record, tag, dwell, menu) before you depend on it.
3. **Flash the rebuilt boot image** (scripts/14) from that fastboot
   session. Boot with the SSD: expected result — console stays on the TV
   the whole boot (or, per §a, we learn the real killer from the journal +
   the TV's OSD). Console login should work — scripts/13 leaves the ALARM
   default passwords in place for the TV (its sshd config comment says
   exactly that) — verify which, before you need it blind.
4. **Kernel crypto rebuild + rootfs rewrite + reflash** (scripts/11, 13,
   15, 14 in one session — FIT and `/lib/modules` from the same build,
   per §c), with `device-info/wifi` filled in (scripts/13:155-163 already
   turns SSID+PASSPHRASE into an iwd profile; SSH root key already wired,
   scripts/13:70-76). After this boot, iwd should join WPA2/WPA3-Personal
   and you have SSH.
5. **Gadget channel** last (§d), as the permanent debug link.

Other risks worth naming:

- **The watchdog bounds the fastboot window** (~35 s after the 60 s log;
  §b.1). Flash promptly; the loop is recoverable but wastes minutes.
- **Journal timestamps are wrong** (no RTC, 2026-10-18 in the log). Harmless
  for WPA2 (no time dependency), but don't correlate journal times across
  boots; use `journalctl -b` boundaries. Once NTP exists this self-heals.
- **Power-yanking the SSD**: boot 1 ended with a USB reset around the pull.
  ext4 journaling survives it, but once you have SSH/console, shut down
  with `systemctl poweroff` instead.
- **Keep Android off this disk's life**: fine today (Linux lives on the
  SSD's `darcy-root`, UDA untouched), and `vendor_flash_recovery` only runs
  under Android — which can no longer boot since its LNX slot holds U-Boot.
  Just don't restore `boot.img` casually while depending on the current
  chain.
- **Nothing else in the plan looks wrong**: `max-reason = <1>` is correct;
  `rootwait=30` reliably panics without the SSD; the recovery slot keeping
  the test payload is a good standalone report channel; the Wi-Fi and
  crypto list is complete per §c.

### TL;DR

- (a) `module_blacklist=tegra-drm` — dash, not underscore
  (`kernel/module/main.c:2936` exact match; module is `tegra-drm.ko`). But
  tegra-drm's aperture removal is CRTC-guarded (`drm.c:1259`) and no CRTC
  existed (`drm_fb_helper.c:1487` says so) — it likely wasn't the killer;
  treat the next boot as diagnostics (TV OSD wording + journal grep).
  nouveau can't even load (gpu node disabled); host1x and snd-hda are
  verified harmless.
- (b) Panic route is sound, end-to-end, per the patch code and DT; budget
  ~35 s of fastboot before the still-armed watchdog resets; the hang/
  watchdog variant stays unverified until cboot's string is seen once.
- (c) List is complete for WPA2/3-Personal (ECC/ECDH/AES-CE already =y);
  `CRYPTO_USER_API` self-promotes via `select`; keep
  `CRYPTO_USER_API_ENABLE_OBSOLETE=y`. Old modules would load (vermagic
  only) but never mix builds — you're rebuilding the SSD anyway.
- (d) XUDC gadget on the far port: config already there, ~half a day of
  DT (xudc node + usb2-0 lane/port) + one configfs script; hardware path
  proven by cboot's own fastboot on that port.
- (e) Order: fix spelling → prove panic route on the current image →
  flash → console on TV → crypto+Wi-Fi rebuild → gadget. Watch the WDT
  window, verify the TV login credentials, and shut down cleanly once you
  can.
