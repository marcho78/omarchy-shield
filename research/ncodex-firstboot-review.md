# First-boot review: Darcy installed system

## Verdict

There is no critical blocker in the proposed display or Wi-Fi fixes. `module_blacklist=tegra_drm` is the correct strong containment for the observed blackout, and the SSD-less recovery path is sound on this 7.2 kernel. The two material cautions are:

1. Do not treat `CONFIG_MODVERSIONS=n` as permission to mix kernel modules from different builds. Install the complete matching module tree with the new FIT.
2. Do not combine the first recovery update with XUDC work. The far Type-A port's role/VBUS wiring is unusual, and the current gadget stack is modular, so it is not yet a root-independent rescue channel.

The simplest immediate recovery does not require fastboot: edit the removable SSD on the laptop to prevent `tegra_drm` loading, boot the existing image, then use the now-visible console to run a clean `reboot bootloader`. A temporary systemd unit on the SSD can do that reboot unattended as well.

## Findings, ranked

### Medium: reinstall all modules from the new kernel build

**VERIFIED.** With `CONFIG_MODVERSIONS` off, symbol CRC checks are compiled out (`vendor/linux/kernel/module/internal.h:404-422`). The loader still compares vermagic (`vendor/linux/kernel/module/main.c:2645-2662`), but vermagic contains the kernel release and broad build attributes, not a complete ABI description (`vendor/linux/include/linux/vermagic.h:12-46`). A configuration rebuild at the same source commit can therefore retain the same release/vermagic while changing layouts or available symbols.

Rebuild and install the entire `/usr/lib/modules/$(kernelrelease)` tree, including the new `modules.dep`, `modules.alias`, and `modules.builtin`; do not copy only the newly enabled crypto modules. `scripts/13-make-rootfs.sh:122-126` already performs a full `modules_install`, so the proposed rebuild/rewrite is correct. For safer two-device updates, consider giving each kernel/module set a distinct local version or retaining both module directories until the new FIT is proven; otherwise an old FIT plus overwritten same-release modules is an avoidable mismatch window.

### Medium: XUDC is feasible, but not yet a rescue channel

Details are in section (d). In short, the DT wiring is well evidenced, but fixed peripheral role/VBUS detection on Darcy's Type-A OTG port needs an isolated test. The present `tegra-xudc`, libcomposite, ACM/NCM/ECM, and configfs pieces are modules (`build/linux/.config:6556-6579`); with no `/init` in the initramfs, none can help when the SSD/root is missing.

### Low: the SSD-less panic path has a second, slower watchdog fallback

The expected path is approximately 30 seconds of `rootwait`, then a panic, then the `panic=10` reset. If that path fails before userspace, U-Boot's still-running 150-second watchdog should reset into the watchdog branch. The only common dependency is that U-Boot must find a valid tagged ramoops console; this is strongly supported by the code but the installed-system branch has not been exercised end to end.

## (a) Keeping simpledrm

**VERIFIED: the blacklist is correct and sufficient for the current tree.**

- The module's internal name is `tegra_drm` (also reported by `modinfo` on `build/linux/drivers/gpu/drm/tegra/tegra-drm.ko`), so `module_blacklist=tegra_drm` in `kernel/dts/darcy-system.dts:24` is correctly spelled.
- This is a kernel-enforced blacklist, not merely a modprobe alias rule. The kernel parses the comma-separated list at `vendor/linux/kernel/module/main.c:2934-2953` and rejects any attempted load with `-EPERM` at `:3402-3409`, including an explicit `finit_module()`.
- The observed destructive action is exactly in that module: after at least one CRTC has registered, `aperture_remove_all_conflicting_devices()` runs at `vendor/linux/drivers/gpu/drm/tegra/drm.c:1250-1262`; registration/client setup follows at `:1271-1275`. Blocking the module prevents both the display-component drivers and this aperture takeover (`drivers/gpu/drm/tegra/Makefile:4-35`, `drm.c:1413-1448`).
- `host1x` has `MODULE_SOFTDEP("post: tegra-drm")` (`vendor/linux/drivers/gpu/host1x/dev.c:827`), but host1x itself contains no aperture-removal call. The kernel blacklist still refuses the post-load request.
- `nouveau` cannot normally bind: the integrated GM20B node remains `status = "disabled"` (`vendor/linux/arch/arm64/boot/dts/nvidia/tegra210.dtsi:440-456`), and `darcy.dts` does not enable it. Nouveau's conflicting-framebuffer removal is in its PCI probe (`drivers/gpu/drm/nouveau/nouveau_drm.c:858-879`), whereas the Tegra platform path at `:1448-1476` has no such call.
- `snd-hda-tegra` cannot bind because `hda@70030000` remains disabled (`tegra210.dtsi:1063-1076`); `darcy.dts:132-134` only deletes its power-domain property. It has no framebuffer-aperture path anyway.

Thus no extra blacklist is needed now. Blacklisting `host1x` or `nouveau` would only be belt-and-suspenders and would hide useful failures. **UNCERTAIN:** a future DT that enables GM20B, HDA, or another DRM device must be reviewed again; this conclusion is for the current compiled tree.

For an immediate no-fastboot workaround, add both `blacklist tegra_drm` and `install tegra_drm /bin/false` under `/etc/modprobe.d/` on the SSD. That is weaker than the kernel command-line blacklist against a direct syscall, but sufficient for ordinary udev/kmod autoload and should preserve the display on the already-installed boot image.

## (b) SSD-less recovery and alternatives

**VERIFIED: the intended panic is supported by this kernel.** Unlike older kernels, this tree implements bounded `rootwait=`: it parses seconds at `vendor/linux/init/do_mounts.c:74-97`, waits until the deadline at `:406-424`, and then attempts the mount. Failure reaches the VFS panic paths at `do_mounts.c:183,229-242`. Therefore `rootwait=30 panic=10` is not an indefinite wait.

**VERIFIED: ramoops and U-Boot agree on layout and reason filtering.**

- `max-reason = <1>` is in `kernel/dts/darcy-system.dts:34-36`; enum value 1 is `KMSG_DUMP_PANIC` (`include/linux/kmsg_dump.h:23-29`), and reasons numerically above the maximum are skipped (`kernel/printk/printk.c:4860-4884`).
- Linux allocates dump records first, then console, then pmsg (`fs/pstore/ram.c:784-802`). U-Boot computes the same layout (`patches/u-boot/0001-...patch:765-794`) and `dump_recorded()` accepts a record only with the persistent-RAM signature and a sane nonzero size (`:803-815`).
- For a system payload, U-Boot enters fastboot only if there is a dump or watchdog reason **and** `report_last_log()` finds a valid console containing `darcy.chain=u-boot` (`:848-883, 967-985`). The tag is added in `ft_board_setup()` (`:993-1028`). Pstore registers its console with `CON_PRINTBUFFER`, so early command-line output containing the tag is replayed (`vendor/linux/fs/pstore/platform.c:409-424`).

If the panic record is not recognized, the 150-second watchdog is a fallback. U-Boot arms it at patch lines `920-936`; `tegra_wdt`'s probe registers the device without stopping/reprogramming an already running watchdog (`vendor/linux/drivers/watchdog/tegra_wdt.c:182-230`). With no root, systemd never opens `/dev/watchdog0`, so it should expire. The hardware reset itself has already been proven (`NOTES.md:714-727`). **UNCERTAIN:** the complete installed-system `dump_recorded()`/`watchdog_reset()` decision has not itself been observed on-device.

Better entry methods, in preferred order:

1. Mount the SSD on the laptop and add the temporary modprobe block above. Boot, log in on the restored TV console, and run `systemctl --reboot-argument=bootloader reboot`. Linux programs the scratch bit for the literal `bootloader` argument (`drivers/soc/tegra/pmc.c:1158-1188`), and this route was already proven on Darcy (`NOTES.md:656-662`).
2. If blind/unattended entry is desired, put a temporary enabled oneshot service on the SSD whose `ExecStart` is `/usr/bin/systemctl --reboot-argument=bootloader reboot`. Systemd 262 documents that option as the argument passed to `reboot(2)`. Remove/disable the unit after reaching fastboot, or every successful boot will return there.
3. Use the SSD-less panic route. It is sound and non-destructive, just less direct.

## (c) iwd crypto and module compatibility

**VERIFIED: the proposed missing options are sufficient for iwd 3.12's startup test.** The authoritative check is `src/main.c:273-402` in the upstream [`iwd-3.12` source](https://www.kernel.org/pub/linux/network/wireless/iwd-3.12.tar.xz). It tests HMAC-SHA1/MD5/SHA256, CMAC-AES, DES/3DES, AES, SHA512, CBC, AF_ALG hash/skcipher, keys, and DH. The journal's long list is partly diagnostic fallout: when the AF_ALG interfaces are absent, iwd reports their backing algorithms even where the algorithms are already built in.

The six proposed changes cover the actual differences:

- `CRYPTO_USER_API_HASH=y` and `CRYPTO_USER_API_SKCIPHER=y` each select `CRYPTO_USER_API`, so the current parent `=m` will become built-in (`vendor/linux/crypto/Kconfig:1234-1260`). Explicitly setting `CONFIG_CRYPTO_USER_API=y` too is harmless and clearer, but not required by Kconfig.
- `KEY_DH_OPERATIONS=y` selects its DH/KDF dependencies (`security/keys/Kconfig:110-118`). It is used by iwd for WPS, not SAE.
- Making MD5 and DES built-in avoids reliance on early module/autoload behavior. ECB, CBC, SHA1/256/512, AES, CMAC, and HMAC are already `=y` in the effective config.
- `PKCS8_PRIVATE_KEY_PARSER=y` is not needed for WPA2/WPA3-Personal; it is for loading PKCS#8 private keys, primarily enterprise TLS. It is still the clean fix for iwd's installed `modules-load.d/pkcs8.conf`, whose own comment says it exists only to load the parser when configured `=m`. Its prerequisite `ASYMMETRIC_PUBLIC_KEY_SUBTYPE=y` is already satisfied (`build/linux/.config:8878-8882`; Kconfig at `crypto/asymmetric_keys/Kconfig:37-45`).

No additional SAE kernel crypto switch is indicated. iwd's SAE implementation uses ELL's `l_ecc_*` and HMAC routines in userspace (`iwd-3.12/src/sae.c`); `CONFIG_CRYPTO_ECDH=y` is already present anyway. AES-CE is an optimization, not a functional prerequisite, and `CONFIG_CRYPTO_AES_ARM64_CE_BLK=y` is already enabled (`build/linux/.config:8842`).

**UNCERTAIN:** WPA3-SAE also depends on the BCM4354 firmware/driver capability, not these crypto switches. Brcmfmac derives `sae`/`sae_ext` from the firmware capability string (`drivers/net/wireless/broadcom/brcm80211/brcmfmac/feature.c:37-48,228-250`) and advertises SAE only when those bits exist (`cfg80211.c:7695-7712`). I found no evidence here that NVIDIA's particular BCM4354 firmware advertises either. Verify after boot with `iw phy`/iwd logs; a transition-mode AP may merely fall back to WPA2, while SAE-only may fail.

The Wi-Fi profile construction itself is reasonable: `scripts/13-make-rootfs.sh:155-168` writes a mode-0600 iwd `.psk` with `Passphrase=`, and `device-info/` is git-ignored (`.gitignore:1-3`). Remember that the passphrase also exists in the generated rootfs image/build artifacts; do not publish them.

## (d) USB gadget debug channel

This is **moderate board/DT work plus straightforward gadget setup**, with one board-specific uncertainty.

For a minimal USB 2 device-mode experiment, `darcy.dts` would need:

1. Enable padctl lane `usb2-0` with `nvidia,function = "xusb"`.
2. Enable padctl port `usb2-0` as peripheral (or OTG), with `usb-role-switch`; the Tegra padctl driver rejects peripheral/OTG mode without that property (`drivers/phy/tegra/xusb.c:743-781`). A fixed initial device role can use `role-switch-default-mode = "peripheral"`.
3. Enable `/usb@700d0000` with the `usb2-0` PHY, `phy-names = "usb2-0"`, `avddio-usb-supply = <&max77620_ldo1>`, and `hvdd-usb-supply = <&vdd_3v3>`. The base node already supplies registers, clocks, interrupts, and power domains (`arch/arm64/boot/dts/nvidia/tegra210.dtsi:1370-1386`); the binding requires the two supplies for T210 (`Documentation/devicetree/bindings/usb/nvidia,tegra-xudc.yaml:92-145`).
4. Only later, for SuperSpeed, also enable lane `pcie-6`, port `usb3-0` with companion 0, and add the `usb3-0` PHY. Stock downstream Darcy confirms exactly `usb2-0` plus `pcie-6` (`vendor/lineage-t210-foster/kernel-dts/tegra210-darcy-p2894-common.dtsi:166-249,273-284`).

**UNCERTAIN / electrical caution:** Darcy exposes this dual-role connection through a full-size Type-A receptacle. Stock downstream senses VBUS on Tegra GPIO Z0 (active low) and ID on MAX77620 GPIO0 (`...darcy-p2894-common.dtsi:221-235`; `...darcy-extcon-p2894-0000-a00.dtsi:17-59`). Mainline uses `vbus-gpios`/`id-gpios` and its connector model does not neatly describe this unusual Type-A device port (`Documentation/devicetree/bindings/connector/usb-connector.yaml:17-67`). Start fixed in **peripheral** role and USB2-only. Do not enable a VBUS-source regulator while the laptop is attached; both ends sourcing 5 V is the material hardware risk.

There are two debug levels:

- **After root mounts:** current modular XUDC/configfs/ACM/NCM support is enough. A systemd unit can create an ACM plus NCM/ECM configfs gadget, bind it to the UDC, start `serial-getty@ttyGS0`, and configure a static USB-network address/SSH. This helps when display/Wi-Fi fail but root succeeds.
- **Root-independent:** build `CONFIG_USB_TEGRA_XUDC=y`, `CONFIG_USB_G_SERIAL=y`, and `CONFIG_U_SERIAL_CONSOLE=y` (padctl is already built-in). The legacy serial gadget registers itself (`drivers/usb/gadget/legacy/serial.c:287-318`), and u_serial registers `ttyGS0` as a `CON_PRINTBUFFER` console (`drivers/usb/gadget/function/u_serial.c:1077-1111,1330-1337`), so prior kernel messages are replayed once USB connects. It still needs a getty for interactive login; with no `/init`, it provides diagnostics but cannot supply a shell. USB Ethernet likewise cannot configure IP/SSH before userspace.

Use either legacy `g_serial` or a configfs composite gadget, not both competing for the one UDC.

## (e) Safer, simpler order

1. On the laptop, preserve the current journal and add the temporary `/etc/modprobe.d` block to the SSD. Optionally add the one-shot bootloader reboot unit instead. This avoids depending on the untested system-panic branch merely to regain control.
2. Boot the unchanged system and verify that simpledrm survives. Then cleanly enter fastboot with `systemctl --reboot-argument=bootloader reboot`.
3. Build one new kernel/FIT containing only the kernel-command-line blacklist and crypto/parser options. Install its complete matching modules on the SSD and put the iwd profile there. Keep the SSD and FIT update paired; do not boot between halves of a same-release update.
4. Flash only the boot image, boot with the SSD, then verify in order: simpledrm remains, iwd stays active, WPA2 joins, SSH works, and finally WPA3 capability. Also configure a regulatory country; the existing `set-wireless-regdom` failure is separate from crypto and can affect channel availability.
5. Add XUDC in a later, isolated FIT. Prove USB2 serial first, then add composite Ethernet and only then SuperSpeed/OTG role sensing.

Rewriting the SSD from the reproducible image is valid, but it discards the useful journal and any live edits; retain a copy first. Do not make the first recovery boot simultaneously test a new kernel config, a rewritten root, new Wi-Fi credentials, and an unproven OTG DT.
