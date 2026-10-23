# Step 3 review

The crypto change is the right kernel for iwd, and it does not disturb anything else that is already booting. Keep `cfg80211.ieee80211_regdom=US`: on this board it never reaches the firmware, so a missing CLM entry cannot reject it. `scripts/16` is the right way to update the one release directory. Flash that FIT only after step 2 has a picture, with the SSD still on the laptop, and do not press Continue in the gap.

iwd 3.12's source was not read. The startup claim is the journal's missing-option list against `build/linux/.config`, which iwd can see because `CONFIG_IKCONFIG_PROC=y` (`:160-161`).

## a) These options make iwd start, and they cover a WPA2-PSK join

All seven are `=y` in the rebuilt config, and nothing in the set was dropped:

| Option | Result | Why it stuck |
|---|---|---|
| `CRYPTO_USER_API_HASH`, `CRYPTO_USER_API_SKCIPHER` | `=y` (`build/linux/.config:8832-8833`) | Depend on `NET`, select `CRYPTO_USER_API` (`vendor/linux/crypto/Kconfig:1237-1260`). `CRYPTO_USER_API` moved from `=m` to `=y` (`:8831`). |
| `KEY_DH_OPERATIONS` | `=y` (`:8615`) | Selects `CRYPTO_DH` and `CRYPTO_KDF800108_CTR` (`vendor/linux/security/keys/Kconfig:110-114`). Both are `=y` (`:8725`, `:8825`). |
| `CRYPTO_MD5`, `CRYPTO_DES` | `=y` (`:8789`, `:8744`) | No `CRYPTO_USER_API_ENABLE_OBSOLETE` dependency (`crypto/Kconfig:458-465` for DES). They were `=m`, which is why iwd reported them missing before anything had loaded them. |
| `PKCS8_PRIVATE_KEY_PARSER` | `=y` (`:8882`) | Depends on `ASYMMETRIC_PUBLIC_KEY_SUBTYPE`, which is `=y` (`:8880`, `crypto/asymmetric_keys/Kconfig:37-39`). |

The other names iwd printed were already built in and are unchanged: `CRYPTO_ECB`, `CBC`, `AES`, `CMAC`, `HMAC`, `SHA1`, `SHA256`, `SHA512` (`:8737`, `:8760`, `:8763`, `:8786-8793`). `CRYPTO_MANAGER=y` (`:8709`). `CRYPTO_ECDH` was already `=y` (`:8728`); this diff did not add it.

`CRYPTO_USER_API=y` builds `af_alg`, `algif_hash`, and `algif_skcipher` into vmlinux. They now appear in `modules.builtin` (`build/linux/modules.builtin:64-66`), so iwd's AF_ALG sockets do not wait for a module. `CRYPTO_USER_API_ENABLE_OBSOLETE` stays at its default `y` (`crypto/Kconfig:1328-1331`). That default does not enable ciphers by itself: `CRYPTO_ANUBIS` and `CRYPTO_ARC4` are still off (`:8738`, `:8758`). No boot path other than iwd's PKCS#8 modules-load snippet asks for these. With the parser built in, that snippet no longer has a `.ko` to load. The feature is present; a red modules-load line is cosmetic and is not what stopped iwd. WPA2-PSK does not use PKCS#8.

WPA2-PSK on `brcmfmac` splits in two. The 4-way handshake in iwd uses the AF_ALG hash and skcipher interface (HMAC, SHA, AES), which this set provides. CCMP on the air is the firmware's, and `brcmfmac` is already built in and already brought `wlan0` up. `CRYPTO_USER_API_AEAD` is still unset (`:8835`) and `CRYPTO_CCM` is still `=m` (`:8774`). Those were not in the failure list. A WPA2-PSK network does not need them. A WPA3-SAE-only network is **UNCERTAIN** and is outside this step; a mixed WPA2/WPA3 AP should still be joined as PSK.

## b) Keep `cfg80211.ieee80211_regdom=US`

`brcmfmac` does register a reg notifier (`vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/cfg80211.c:8374-8377`). For an ISO country it reads the firmware country, translates, and writes it back (`:8250-8279`). The translation is the part that does not run here:

- `wifi@1` has no `brcm,ccode-map` and no `brcm,ccode-map-trivial` (`kernel/dts/darcy.dts:221-227`). With no map, `brcmf_of_get_country_codes` leaves the table empty (`of.c:26-37`).
- The ISO fallback is only for a trivial map or chip ids 43430, 4345, 4356, and 43602 (`cfg80211.c:7945-7958`). BCM4354 is `0x4354` (`brcm_hw_ids.h:39`) and is not in that list.
- So `brcmf_translate_country_code` returns `-EINVAL` (`cfg80211.c:7976-7988`) and the notifier returns (`:8271-8273`) without `brcmf_fil_iovar_data_set("country")`. The "Firmware rejected country setting" line (`:8276-8278`) is the path after a translation succeeded. This boot does not take it.

A missing US entry in NVIDIA's CLM blob is therefore not consulted. The firmware country stays at the NVRAM value, `ccode=XV` / `regrev=0` (`recovery/9.1.1/vendor-firmware/nvram_darcy_a00.txt:16-17`). The kernel parameter cannot make that firmware reject a country, and it cannot make the CLM situation worse.

What it does change is cfg80211. The parameter is `ieee80211_regdom` (`vendor/linux/net/wireless/reg.c:276-281`). `regulatory.db` and `regulatory.db.p7s` are already in the FIT initramfs (`config.sh:66-73`, packed by `scripts/12-make-payload.sh:49-68`), and the kernel requires a signed db (`build/linux/.config:1658-1659`). Once that db loads, US replaces the world domain. Until a user or country-IE hint lands, `brcmfmac`'s own domain is in force: alpha2 `99`, channels 1-13, 14, 36-64, and 100-165, with no `NO_IR` flag (`cfg80211.c:219-233`). US is stricter than that (no channel 12-14, DFS where the db says so). For a US AP on 1-11 or a non-DFS 5 GHz channel, stricter is the domain you want. It is not a regression against the world domain the failed `set-wireless-regdom` unit left in place.

Keep the parameter. Drop it only if the AP is not in the US. Do not add `brcm,ccode-map-trivial` in this step: that is the switch that would send `ccode=US` to the firmware, which is the untested CLM case.

If the signature check fails, the journal says the db is malformed or the signature is missing, and the `99` domain remains. Wi-Fi still comes up. Absence of "Firmware rejected country setting" does not mean the firmware country changed.

## c) `scripts/16` updates the right directory, and nothing else on the SSD has to move

For one USB disk named `darcy-root`, the script does what it says.

- The partlabel symlink is resolved and rejected unless it is a block device (`scripts/16-update-usb-disk.sh:19-20`). The parent must be a USB disk (`:21-22`), the same test as `scripts/15-write-usb-disk.sh:30`.
- `make modules_install` stages into `build/modules` (`:26-27`). That target runs depmod (`vendor/linux/scripts/Makefile.modinst:128-135`) with `-b` pointed at the staging tree (`scripts/depmod.sh:28-32`). `build/linux/System.map` exists, so the "skip depmod" branch (`depmod.sh:15-18`) does not apply. The host `depmod` indexes the modules; `scripts/13` already installed a bootable tree this way.
- The rsync source and dest both end at `.../modules/7.2.11-ga2de78ee6ed8/` (`kernel.release` is that string). `--delete` applies only inside that directory. The journal, `/etc`, and firmware on the disk are outside it. `--chown=0:0` under sudo is the right owner. `set -euo pipefail` is on (`scripts/lib.sh:2`).
- The release string did not change, so this replaces the directory the running system already uses, rather than leaving a second tree beside it.

Stale `build/linux/crypto/md5.ko` and `des_generic.ko` are on disk from the `=m` build. They are not in `modules.order`. `modules_install` installs only `modules.order` (`Makefile.modinst:43`). Both names are in `modules.builtin` (`:47`, `:54`), which is what gets installed for them, along with `pkcs8_key_parser` (`:71`). The orphan `.ko` files are not copied. `--delete` then removes the copies the old image left under that release on the SSD.

Two holes, neither of them the common case:

- If `udisksctl mount` returns success and `findmnt` still returns nothing, `mnt` is empty and `[[ -d $mnt/usr/lib/modules ]]` is true on this laptop (`:30-35`). The rsync would then create `/usr/lib/modules/7.2.11-ga2de78ee6ed8` on the host. It would not touch the host's own kernel directory, because the release string differs. A failed `udisksctl` aborts first, because of `set -e`. Die when `mnt` is empty, before that test.
- Unlike `scripts/15`, this script does not print the disk or ask for its name. `/dev/disk/by-partlabel/darcy-root` is one symlink. Two USB disks with that label are ambiguous. With only the SHIELD disk plugged in, the USB check is enough.

Nothing else on the SSD has to change for this kernel. `brcmfmac`, `cfg80211`, and the Wi-Fi firmware are built in or already in the FIT initramfs; `wlan0` already came up from that firmware. `regulatory.db` is in the initramfs too. The command line and the new kernel arrive by the boot-partition flash, not by a file on the SSD. iwd, `wl.network`, and the SSH key are already on the disk from `scripts/13`. The SSID is typed on the TV in this plan, so `device-info/wifi` is not required for the try.

The `build` symlink is removed before the copy (`scripts/16:28`); `scripts/13` does the same. A `source` symlink left behind points at the host tree and is unused on the device.

If `udisksctl unmount` fails, `set -e` exits after the `sync` (`:39-40`) and the "done" line is not printed. The copy is already on the disk. Unplug only after the filesystem is actually unmounted.

## d) The sequence is the right one. This particular mismatch would still boot

`systemctl --reboot-argument=bootloader reboot` is the `reboot(2)` argument `bootloader`. Tegra's reboot notifier writes `PMC_SCRATCH0_MODE_BOOTLOADER` for that string (`vendor/linux/drivers/soc/tegra/pmc.c:1170-1171`, called on `SYS_RESTART` at `:1185-1186`). cboot then opens the menu instead of starting U-Boot. That path is already proven for `reboot bootloader` (`NOTES.md:656-661`). Plug the fastboot cable into the far port before the reboot, or the menu has nothing for `scripts/14` to talk to.

Order that keeps the next Linux boot on a matched pair:

1. From the step-2 console, reboot to the menu. The boot partition still holds the step-2 FIT, the SSD still holds the old modules.
2. Move the SSD to the laptop. Run `scripts/16`. `scripts/12 --system` does not touch the disk and can run before or after it. Leave the SHIELD on the menu.
3. `CONFIRM_FLASH=yes scripts/14-install-system.sh`. With `SYSTEM_ROOT=PARTLABEL=darcy-root` this writes the boot partition only (`scripts/14-install-system.sh:33-36`, `:73-74`). It checks `root=` in the new dtb (`:31-32`) and does not check that `WIFI_COUNTRY` was substituted; the `scripts/12` log line is that check. Do not pass `--restore`.
4. Put the SSD back, then Continue.

The gap is step 2's FIT plus the new module tree if Continue is pressed before the flash. No menu timeout is documented; the notes show Continue pressed by hand (`NOTES.md:654`, and `scripts/14:79`). There is no software lock.

For this delta the gap is survivable, which is why it must not be confused with a real ABI break. The release string is still `7.2.11-ga2de78ee6ed8`, and `MODVERSIONS` is off, so vermagic matches. The crypto change is entirely built in. `module_blacklist=tegra_drm` is on both command lines. An old FIT with the new modules, or a new FIT with the old modules, should still boot and should still keep the picture. The old `md5.ko` and `des_generic.ko` are redundant once the algorithms are built in. Do the matched order anyway. The next config change will not have this property, and `scripts/16`'s header is the rule to keep.

There is no simpler route that still flashes from the menu. The SSD cannot be updated in place while the system is running and then flashed without a menu visit, and there is no network yet to copy modules the other way.

## e) What can still stop the first join or the first SSH

- **5 GHz and `ccode=XV`.** The file NVRAM is used as-is. The rewrite of `ccode=XV` to `ccode=X2` exists only for an EFI variable (`vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/firmware.c:464-511`), and this machine does not boot Linux through EFI. The driver's comment says `ccode=XV` makes every 5 GHz channel unavailable. That is the driver's statement about the ccode, not a scan of this firmware. A 5 GHz-only AP may be missing while 2.4 GHz works. The US parameter does not change this. Leave the NVRAM file alone in this flash. If the scan is 2.4 GHz only, the follow-up is that X2 substitution, which is untested against NVIDIA's CLM.
- **Channels 12-14.** US drops them. A US AP on 1-11 is unaffected.
- **WPA3-SAE only.** Uncertain, as in (a). Use a WPA2-PSK network for the first try.
- **MAC `00:90:4c:16:70:01`** (`nvram_darcy_a00.txt:14`, `NOTES.md:920-922`). One SHIELD on the AP is fine. A second device with the same placeholder collides.
- **`set-wireless-regdom` will still fail.** The image has no `iw` (`config.sh:101-103`). That unit is not the country setting anymore. Ignore it once the new FIT's log shows the regdom change, or shows the signed-db failure from (b).
- **DHCP is untested.** `scripts/13` writes `wl.network` with `Name=wl*`, which matches `wlan0` (`scripts/13-make-rootfs.sh:145-153`). The base image's Ethernet path is systemd-networkd (`NOTES.md:890-891`). No boot has had a Wi-Fi carrier, so a lease is the part to watch. There is no avahi package (`config.sh:118-123`). Read `ip -4 addr show wlan0` on the TV, then SSH as root with `device-info/ssh/id_ed25519`.
- **SSH.** The drop-in turns password authentication off and the image installs `root`'s `authorized_keys` (`scripts/13-make-rootfs.sh:171-177`). OpenSSH's default `PermitRootLogin prohibit-password` allows that key. The main `sshd_config` inside the image was not opened. The wrong clock does not stop ed25519.
- **Login on the TV** is `root`, short, not starting with `-`. iwd's old start-limit counter clears on this reboot.
- **Step 2 first.** This FIT is not built yet, and `build/boot-uboot-darcy-system.img` is still the blacklist image. Flash that one, get the picture, then do this sequence.
