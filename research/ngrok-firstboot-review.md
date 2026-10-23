# First-boot review

The installed system is locked out only while the SSD is attached and udev loads `tegra-drm`. The already-built FIT with `module_blacklist=tegra_drm` is the right next flash. Reach fastboot by booting that same kernel with the SSD unplugged: the panic path is sound, and the picture should stay up on that boot because `tegra-drm` is a module on the missing disk. Do the crypto rebuild and the Wi-Fi credentials as a later image. Do not run `scripts/15` to "reinstall modules"; it erases the disk.

The combination "system FIT + `max-reason = <1>` + no SSD" has not been run. The pieces below are each verified in this tree, and the panic, ramoops, and watchdog returns were already proven on the test payload (`NOTES.md:645-727`).

## a) `module_blacklist=tegra_drm` is the right fix, and it is sufficient for the failure you saw

The string is already on the unflashed command line (`kernel/dts/darcy-system.dts:24`). It matches the module name, not the filename. The object is `tegra-drm.o` (`vendor/linux/drivers/gpu/drm/tegra/Makefile:35`). Kbuild turns the dash into an underscore for `KBUILD_MODNAME` (`vendor/linux/scripts/Makefile.lib:19-23`), and modpost writes that as `MODULE_INFO(name, ...)` (`vendor/linux/scripts/mod/modpost.c:1866`). The blacklist compares that name exactly (`vendor/linux/kernel/module/main.c:2944-2947`) and refuses the load (`:3406-3408`). A journal line `Module tegra_drm is blacklisted` is the confirmation.

`tegra-drm` is the driver that removes simpledrm. It calls `aperture_remove_all_conflicting_devices()` only when `mode_config.num_crtc > 0` (`vendor/linux/drivers/gpu/drm/tegra/drm.c:1259-1260`), then `drm_dev_register` (`:1271`) and `drm_client_setup` (`:1275`). "Cannot find any crtc or sizes" is the fbdev helper after that, when `crtc_count == 0` or no mode has a size (`vendor/linux/drivers/gpu/drm/drm_fb_helper.c:1486-1488`). The journal order matches: CRTCs were registered (so the aperture call ran and simpledrm died), then the helper found nothing it could scan out. `pd_sor` is already deleted (`kernel/dts/darcy.dts:140`), which is why the link survives until this module loads.

Nothing else in a normal boot of this DT takes the framebuffer:

- `host1x` has no `aperture_remove` anywhere under `vendor/linux/drivers/gpu/host1x`. It is the bus. DC and SOR are compiled into `tegra-drm`, so they do not bind while that module stays out. udev may still load `host1x.ko`. That does not blank HDMI. Leave it off the blacklist.
- `nouveau` removes a firmware framebuffer only on the PCI probe (`vendor/linux/drivers/gpu/drm/nouveau/nouveau_drm.c:877`). The platform path, `nouveau_platform_device_create` (`:1448-1476`), does not. `gpu@57000000` (gm20b) is `status = "disabled"` (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:440-456`), and `darcy.dts` does not enable it. Nouveau should not probe.
- `snd-hda-tegra` (`vendor/linux/sound/hda/controllers/tegra.c`) has no aperture call. `hda@70030000` is `status = "disabled"` (`tegra210.dtsi:1063-1076`). `darcy.dts` only deletes its `power-domains` property (`kernel/dts/darcy.dts:132-134`); it does not set the node okay. The driver should not probe, so it will not claim `hda2hdmi` (`tegra.c:542-560`).
- `consoleblank=0` is already on the command line (`darcy-system.dts:24`). The TV went dark at the tegra line, about 3 s into userspace, which is udev and not a logind idle timeout. logind's `IdleAction` was not re-read; it is not the failure in this journal.

After the flash, the new journal must not contain `Initialized tegra`. If the picture still dies, that journal names the other DRM driver. Do not pre-blacklist `host1x`, `nouveau`, or `snd-hda-tegra`.

One consequence for the next step: `tegra-drm` lives on the SSD. The FIT kernel's display driver is built-in simpledrm (`kernel/darcy.config:11`). An SSD-less boot cannot load `tegra-drm`, so the panic text should stay on HDMI. That is from the image layout, not from a boot of this kind.

## b) The SSD-less panic route is sound

`rootwait=30` is a deadline, not an infinite wait. `rootwait=` parses the seconds into milliseconds (`vendor/linux/init/do_mounts.c:74-97`). `wait_for_root` leaves the loop when that deadline passes (`:415-421`). `prepare_namespace` then calls `mount_root` anyway (`:481-483`). A device that never appears hits `panic("VFS: Unable to mount root fs on %s")` (`:229`); a device with no mountable filesystem hits the panic at `:242`. `PARTLABEL=darcy-root` is valid syntax, so the `-EINVAL` path that disables rootwait (`:445-447`) does not apply. The system initramfs has no `/init` (`kernel/dts/darcy-system.dts:3-7`, and the three boots already mounted `root=` themselves), so the firmware cpio is not used as the root. `panic=10` then warm-restarts.

`max-reason = <1>` (`darcy-system.dts:35-37`) is panic-only. The enum is `UNDEF=0`, `PANIC=1`, `OOPS=2` (`vendor/linux/include/linux/kmsg_dump.h:23-29`). The DT value is stored raw (`vendor/linux/fs/pstore/ram.c:695`, `:825`). A dump is skipped when `reason > max_reason` (`vendor/linux/kernel/printk/printk.c:4879`). An oops is not recorded. An empty zone has size 0 and does not count.

The signature U-Boot looks for is the one Linux writes. Dump and console zones are created with sig argument 0 (`ram.c:788-795`). `persistent_ram_post_init` stores `sig ^ 0x43474244` (`vendor/linux/fs/pstore/ram_core.c:39`, `:538-559`), so the header sig is `0x43474244` (`"DBGC"`). U-Boot's `RAMOOPS_SIG` is the same value (`vendor/lineage-u-boot/board/nvidia/p2894/p2894.c:91`). `dump_recorded` is true when any dump zone has that sig, a nonzero size, and a size that fits the record (`p2894.c:566-577`). Sizes in `darcy.dts:35-41` are already powers of two (`record-size` `0x20000`, `console-size` `0x100000`, `pmsg-size` `0x40000`, region `0x200000`), so `ram.c:765-772` does not round them. Dump area is `0xC0000`, six records, then the console. The test-payload loop already found this region, so `ramoops_layout` / `in_dram` is not re-proven here.

U-Boot takes the fastboot path only when all of these hold (`p2894.c:740-748`):

1. The FIT has a device tree and the ramoops layout parses.
2. The payload is not a system payload, or `dump_recorded` is true, or `watchdog_reset` is true (`androidboot.bootreason=watchdog`, `p2894.c:581-591`).
3. `report_last_log` finds `darcy.chain=u-boot` still inside the console zone (`LOG_TAG` at `:106`, written by `tag_bootargs` at `:757-772`; the search is `:611-629`).

On success it prints the tail of the log, zaps the console and every dump record (`:642-645`), waits `darcy_log_secs` (default 60), and `reboot_to(true)` sets `PMC_SCRATCH0_MODE_BOOTLOADER` and warm-resets (`:655-665`). A system payload does not set the recovery bit (`board_quiesce_devices`, `:687-689`), so the panic returns to the boot slot, U-Boot runs again, sees the dump, and only then enters the menu. A normal `reboot` of this payload boots the system again, on purpose (`NOTES.md:855-858`). The laptop should see fastboot drop and come back about 6 s after that second reset (`NOTES.md:656-662`).

Plug the male-to-male USB-A cable into the port farthest from HDMI before power-on (`NOTES.md:62`, `:75-77`). A keyboard in the near port drives the menu (`NOTES.md:69`, `:86-87`). `fastboot reboot recovery` does not work (`NOTES.md:651-654`). No button combo is documented. Hardware Forced Recovery from the menu remains the last resort (`NOTES.md:995-997`).

Two ways this route fails closed, and one backup:

- If `darcy.chain=u-boot` has wrapped out of the 1 MiB console, `report_last_log` returns false and U-Boot boots the system again (`p2894.c:628-629`). An SSD-less boot is short (30 s wait, panic, 10 s), so the tag should still be there. `ignore_loglevel` is on, which makes a long boot noisier; this boot is not long. A miss loops in well under the 150 s watchdog (`p2894.env:16`), and every boot re-arms that watchdog (`p2894.c:683-698`), so a tag miss never falls through to the watchdog path. Pulling power is neither a dump nor `bootreason=watchdog`.
- A leftover nonzero dump from an earlier panic would divert every later boot until `report_last_log` zaps it. The three system boots did not panic. Passing through the bootloader menu clears the ramoops RAM (`NOTES.md:664-667`).
- The backup, if userspace hangs with the watchdog still armed, is the path already proven when that slot was Android: cboot sets `androidboot.bootreason=watchdog` and boots the normal slot (`NOTES.md:714-724`). With U-Boot in the boot slot, that reason is enough even with no dump (`p2894.c:741`).

## c) The iwd list covers the startup check this binary failed. Do not rewrite the SSD for it

Checked against `build/linux/.config`:

| Option iwd printed | Current | What to do |
|---|---|---|
| `CRYPTO_USER_API_HASH`, `CRYPTO_USER_API_SKCIPHER` | not set (`:8831-8832`) | `=y`. These are not modules, so they need a kernel rebuild. Selecting them forces `CRYPTO_USER_API=y` (it is `=m` at `:8830`). |
| `KEY_DH_OPERATIONS` | not set (`:8615`) | `=y`. Same, not a module. |
| `CRYPTO_MD5`, `CRYPTO_DES` | `=m` (`:8789`, `:8744`) | `=y`. iwd treats an algorithm absent from `/proc/crypto` as missing, and nothing loads these before iwd starts. |
| `CRYPTO_ECB`, `CBC`, `SHA1`, `SHA256`, `SHA512`, `AES`, `CMAC`, `HMAC` | already `=y` (`:8737`, `:8760`, `:8763`, `:8786-8793`) | Leave them. |
| `PKCS8_PRIVATE_KEY_PARSER` | not set (`:8881`) | Add it. This is the `pkcs8_key_parser` modules-load failure, not the reason iwd exited. |

`CONFIG_CRYPTO_AES_ARM64_CE_BLK=y` and `CONFIG_CRYPTO_AES_ARM64_CE_CCM=y` are already set (`:8842`, `:8848`). Do not add another AES option. WPA2-PSK packet crypto (CCMP) is `brcmfmac`'s job, and `brcmfmac` plus `cfg80211` are built in (`kernel/darcy.config:32-33`), so the Wi-Fi driver does not come from the SSD module tree. The firmware is already in the FIT initramfs.

`CRYPTO_CCM=m` (`:8774`) and `CRYPTO_USER_API_AEAD` (not set, `:8834`) were not in the failure list. Do not hold the first Wi-Fi image for them. Load or add them only if a later log names them. iwd 3.12's source was not read (the fetch did not return the file). The claim that this list satisfies iwd is verified against the journal's printed list and `.config`, not against iwd's source. Whether a later WPA3-SAE handshake asks AF_ALG for something beyond that list is **UNCERTAIN**. SAE itself is userspace; `KEY_DH_OPERATIONS` is what this binary required in order to stay up.

`MODVERSIONS` is off, so modules match by vermagic, not symbol CRCs. `scripts/11-build-kernel.sh` sets no `LOCALVERSION`. A config change that leaves the release string alone still loads the old modules. The crypto user API and `KEY_DH` do not change `brcmfmac` or DRM structure layouts, and the Wi-Fi driver is built in, so the old module tree is safe to keep for this delta. `=y` for `PKCS8` means there is no `pkcs8_key_parser.ko` afterwards; iwd's modules-load snippet may still print "module not found" even though the parser is built in. That line is harmless once the option is `=y`.

`scripts/15-write-usb-disk.sh` is the wrong tool for a module update. It says everything on the disk is erased (`:6`), then `wipefs`, a new GPT, and `dd` of `build/rootfs.img` (`:42-54`). That throws away the grown rootfs and the journal, which is the only record of these boots. Copy the journal off before any such run. The narrower update, once a new FIT is flashed, is to copy a changed `/lib/modules` tree onto the mounted SSD only if vermagic actually changed.

`device-info/wifi` is the right way to put a network in an image: `scripts/13-make-rootfs.sh:155-168` writes `var/lib/iwd/<ssid>.psk` from `SSID=` and `PASSPHRASE=` lines. It does not set a regulatory domain (no match under `scripts/`). The journal already has `set-wireless-regdom` exit 1. Put a country in the same rootfs update or iwd can start and still refuse to scan. SSH is already arranged by `scripts/13` (`authorized_keys`, `wl.network`). Credentials belong in the image that follows a proven fastboot return. With the TV still dark they are useless until the boot partition can be updated, and they can be dropped onto the mounted SSD without rebuilding it.

## d) A USB gadget on the far port is a later image, not the way back this time

The far port is `usb2-0` / `usb3-0`, the OTG port the laptop's fastboot cable uses, and the laptop powers that cable (`kernel/dts/darcy.dts:142-148`, `NOTES.md:62`). Linux currently leaves it alone. The near port is the host (`usb2-2` plus `pcie-5` as `usb3-1`, `darcy.dts:150-203`) and must stay that way: the hub and the SSD are there.

The device controller exists and is off: `usb@700d0000` (`nvidia,tegra210-xudc`) is `status = "disabled"` (`tegra210.dtsi:1370-1386`). `CONFIG_USB_TEGRA_XUDC=m` (`build/linux/.config:6556`). `CONFIG_USB_GADGET=y`, `CONFIG_USB_CONFIGFS=m` with serial, ACM, ECM, and NCM (`:6532`, `:6574-6579`). `CONFIG_USB_G_SERIAL` is not set (`:6605`). Because the driver is a module, a gadget comes up only after the SSD is mounted. It does not help the SSD-less boot, and it cannot be the first way into fastboot.

The shape to copy is the Jetson Nano's high-speed device, not its role-switch connector. `tegra210-p3450-0000.dts` enables pad lane `usb2-0` with `nvidia,function = "xusb"` (`:467-470`), sets port `usb2-0` okay (`:527-529`), and gives `usb@700d0000` `phys` / `phy-names = "usb2-0"` (`:586-589`). On darcy that is an addition beside the existing host wiring, not a change to `usb2-2` or `pcie-5`. Skip SuperSpeed (`pcie-6`, `NOTES.md:62`) for the first try: the fastboot link is high speed (`NOTES.md:78-80`), and muxing another UPHY lane is the way this port breaks the hub. Skip the Nano's `vbus-supply` and connector. The laptop already drives VBUS; driving GPIO Z0 (`NOTES.md:62`) against that is **UNCERTAIN** and not required for a peripheral.

For a console that does not depend on a configfs script, set `CONFIG_USB_G_SERIAL=y` and `CONFIG_USB_TEGRA_XUDC=y` and add `console=ttyGS0` plus a getty. Configfs ECM gives an IP channel and needs a userspace unit to assemble the gadget; that is more moving parts. Either one is a new FIT, so it waits until the panic route has actually produced fastboot. Probing padctl and xudc reprograms UPHY. Do it with the SSD-less return already proven, so a bad DT is one unplugged disk away from the menu. cboot and U-Boot keep using the port as a USB device before Linux starts.

## e) Order

1. Cable in the far port. Power on with the SSD unplugged. Watch HDMI. Expect the root wait, `VFS: Unable to mount root fs`, the 10 s panic delay, U-Boot's log for about 60 s, then the bootloader menu. The picture should survive this boot.
2. Flash only the boot partition, only the FIT that is already built (`module_blacklist=tegra_drm`, no crypto change). Confirm a picture and a short login name (util-linux 2.42 rejects a name longer than 42 characters or starting with `-`). The new journal must not contain `Initialized tegra`.
3. Rebuild the kernel with the `=y` list in (c). Flash that FIT through the same menu. On the mounted SSD, add the iwd profile and a regulatory country. Copy modules only if vermagic changed. Leave `scripts/15` for a disk you are willing to erase, and copy the journal off first.
4. USB gadget, as its own FIT, only after step 1 has worked once.

Do not combine step 2 with the crypto rebuild. The unflashed FIT predates those options, and a bad new kernel with the SSD attached is the same lockout again. A normal reboot does not enter fastboot. Android must not boot while the Linux rootfs is on `userdata` (`NOTES.md:983-986`). Flash only `boot` or `recovery` (`NOTES.md:988-997`).

`cpufreq-tegra124` probe `-2` and the cpuidle registration failure (`cpuidle.off=1` is intentional) are not what locks the box out. Leave them until there is a shell.
