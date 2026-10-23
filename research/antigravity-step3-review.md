# Step 3 Review: Wi-Fi (`iwd`) + Kernel/Module Update Plan

## Summary Verdict

- **Question (a):** The 6 added `CONFIG_*=y` options in `kernel/darcy.config:36-41` are **complete and sufficient** for `iwd` 3.12 to start cleanly and associate to WPA2-PSK (and WPA3-SAE) networks. All 6 options survived Kconfig resolution as `=y` in `build/linux/.config`, and Kconfig automatically promoted 4 previously modular dependencies (`CONFIG_CRYPTO_USER_API`, `CONFIG_CRYPTO_DH`, `CONFIG_CRYPTO_LIB_DES`, `CONFIG_CRYPTO_LIB_MD5`) from `=m` to `=y` plus newly selected `CONFIG_CRYPTO_KDF800108_CTR=y`.
- **Question (b):** **Verified trap:** `cfg80211.ieee80211_regdom=US` on the kernel cmdline **does not switch the BCM4354 firmware out of `ccode=XV`** and instead causes a **split-brain** between `cfg80211` (`US`) and the BCM4354 firmware (`XV`). While `bcmdhd_clm_darcy.blob` does contain `US` (`rev 0`), mainline `brcmfmac` rejects `"US"` in `brcmf_translate_country_code()` with `-EINVAL` (`"No country codes configured for device"`) because `kernel/dts/darcy.dts:221-227` (`wifi@1`) has no `brcm,ccode-map` property and `brmcf_use_iso3166_ccode_fallback()` does not include `BRCM_CC_4354_CHIP_ID` (`4354`). Either add `brcm,ccode-map = "US-US-0", "XV-XV-0";` to `wifi@1` in `kernel/dts/darcy.dts` (recommended if you keep `ieee80211_regdom=US`), or drop `cfg80211.ieee80211_regdom=US`.
- **Question (c):** `scripts/16-update-usb-disk.sh` is **safe and complete** for updating `/usr/lib/modules/6.6.134+` and installing `/var/lib/iwd/<SSID>.psk`. `make modules_install` reads `modules.order` (not a `*.ko` glob), so stale `.ko` files left over in `build/linux/` from the old `=m` build are not staged, and `rsync -a --delete` removes them from the SSD and updates `modules.dep(.bin)` and `modules.builtin(.bin)`. Two minor script edge cases are noted below.
- **Question (d):** The proposed ordering (Step 2 -> unplug SSD -> Step 3 -> plug SSD -> `fastboot flash boot`) **cannot** boot a mismatched kernel/module pair, and Step 2 is redundant once Step 3 flashes `boot` directly from fastboot, **except** that Step 2 provides a deterministic way to reach fastboot (`systemctl --reboot-argument=bootloader reboot`) without relying on the 5-second panic reboot loop after yanking the live root SSD.
- **Question (e):** Three concrete first-try blockers/hazards to check before running Step 3:
  1. `device-info/wifi` **does not exist yet** in the repo (`ls device-info/` shows no `wifi` file), so `scripts/16-update-usb-disk.sh:104-110` will currently skip installing any `/var/lib/iwd/*.psk` profile.
  2. In `scripts/16-update-usb-disk.sh:81-91`, if `iwd` is Later used interactively or rewrites `/var/lib/iwd/<SSID>.psk`, SSIDs containing spaces, punctuation, or non-alphanumeric characters use `iwd`'s hex-encoding rule (`=xxxxxx`) rather than `tr -cd 'A-Za-z0-9_-'` if `[Security]` does not explicitly contain `Passphrase=`; however, `iwd` **does** still load any `*.psk` file whose `[Settings]` section specifies or omits matching SSID or whose filename matches a simple alphanumeric/hyphen/underscore SSID.
  3. The split-brain caused by `cfg80211.ieee80211_regdom=US` without `brcm,ccode-map` in `kernel/dts/darcy.dts:221-227` (detailed in **(b)**).

---

## (a) `iwd` 3.12 Crypto / Key Option Set & Kconfig Side Effects

### 1. Verification of `build/linux/.config` vs `kernel/darcy.config`

All 6 options added in `kernel/darcy.config:36-41` resolved to `=y` in `build/linux/.config` (verified facts):

| Option in `kernel/darcy.config:36-41` | Old `build/linux/.config.old` | New `build/linux/.config` | Built-in artifact in `build/linux/modules.builtin` |
|---|---|---|---|
| `CONFIG_CRYPTO_USER_API_HASH=y` | `=m` (line 4517) | `=y` (line 4518) | `kernel/crypto/algif_hash.ko` |
| `CONFIG_CRYPTO_USER_API_SKCIPHER=y` | `=m` (line 4518) | `=y` (line 4519) | `kernel/crypto/algif_skcipher.ko` |
| `CONFIG_KEY_DH_OPERATIONS=y` | `# ... is not set` (line 4284) | `=y` (line 4284) | (built into `security/keys/dh.o`) |
| `CONFIG_CRYPTO_MD5=y` | `=m` (line 4460) | `=y` (line 4461) | `kernel/crypto/md5.ko` |
| `CONFIG_CRYPTO_DES=y` | `=m` (line 4399) | `=y` (line 4400) | `kernel/crypto/des_generic.ko` |
| `CONFIG_PKCS8_PRIVATE_KEY_PARSER=y` | `=m` (line 4541) | `=y` (line 4542) | `kernel/crypto/asymmetric_keys/pkcs8_key_parser.ko` |

### 2. Dependencies Automatically Promoted or Pulled in by Kconfig

Diffing `build/linux/.config.old` against `build/linux/.config` (`diff -u build/linux/.config.old build/linux/.config`) shows **only** the 6 requested options plus the following **5 Kconfig-selected dependencies** (no unrelated options changed):

1. `CONFIG_CRYPTO_USER_API`: promoted from `=m` to `=y` (`build/linux/.config:4517`), selected by `CRYPTO_USER_API_HASH=y` and `CRYPTO_USER_API_SKCIPHER=y` (`vendor/linux/crypto/Kconfig:1908,1919`). Builds `kernel/crypto/af_alg.ko` into `Image`.
2. `CONFIG_CRYPTO_DH`: promoted from `=m` to `=y` (`build/linux/.config:4350`), selected by `KEY_DH_OPERATIONS=y` (`vendor/linux/security/keys/Kconfig:104`). Builds `kernel/crypto/dh_generic.ko` into `Image`.
3. `CONFIG_CRYPTO_KDF800108_CTR`: newly enabled as `=y` (`build/linux/.config:4352`), selected by `KEY_DH_OPERATIONS=y` (`vendor/linux/security/keys/Kconfig:105`). Builds `kernel/crypto/kdf_sp800108.ko` into `Image`.
4. `CONFIG_CRYPTO_LIB_DES`: promoted from `=m` to `=y` (`build/linux/.config:4564`), selected by `CRYPTO_DES=y`. Builds `kernel/lib/crypto/libdes.ko` into `Image`.
5. `CONFIG_CRYPTO_LIB_MD5`: promoted from `=m` to `=y` (`build/linux/.config:4566`), selected by `CRYPTO_MD5=y`. Builds `kernel/lib/crypto/libmd5.ko` into `Image`.

Accordingly, `wc -l build/linux/modules.order` dropped by 9 modules (`663` -> `654`).

### 3. Completeness for `iwd` 3.12 + WPA2-PSK (and `systemd-modules-load.service`)

Verified against `build/linux/.config` and `build/linux/modules.builtin`:
- Every required algorithm checked by `iwd` (`ell/missing.h` / `src/main.c` `check_crypto()`) via `AF_ALG` (`algif_hash` / `algif_skcipher`) is now `=y`:
  - Sockets: `CONFIG_CRYPTO_USER_API=y`, `CONFIG_CRYPTO_USER_API_HASH=y`, `CONFIG_CRYPTO_USER_API_SKCIPHER=y`
  - Hashes/MACs: `CONFIG_CRYPTO_HMAC=y` (`build/linux/.config:4439`), `CONFIG_CRYPTO_CMAC=y` (`:4438`), `CONFIG_CRYPTO_MD5=y` (`:4461`), `CONFIG_CRYPTO_SHA1=y` (`:4465`), `CONFIG_CRYPTO_SHA256=y` (`:4468`), `CONFIG_CRYPTO_SHA512=y` (`:4471`), plus ARM64 CE accelerated `SHA1_ARM64_CE=y`, `SHA2_ARM64_CE=y`, `AES_ARM64_CE_CCM=y`, `AES_ARM64_CE_BLK=y` (`:4525-4536`)
  - Ciphers/Modes: `CONFIG_CRYPTO_AES=y` (`:4392`), `CONFIG_CRYPTO_DES=y` (`:4400`), `CONFIG_CRYPTO_ECB=y` (`:4417`), `CONFIG_CRYPTO_CBC=y` (`:4413`)
  - Keyring / EAP / SAE / TLS: `CONFIG_KEYS=y` (`:4279`), `CONFIG_KEY_DH_OPERATIONS=y` (`:4284`), `CONFIG_CRYPTO_ECDH=y` (`:4353`), `CONFIG_ASYMMETRIC_KEY_TYPE=y` (`:4538`), `CONFIG_ASYMMETRIC_PUBLIC_KEY_SUBTYPE=y` (`:4539`), `CONFIG_X509_CERTIFICATE_PARSER=y` (`:4540`), `CONFIG_PKCS7_MESSAGE_PARSER=y` (`:4543`), `CONFIG_PKCS8_PRIVATE_KEY_PARSER=y` (`:4542`).
- Bonus fix: `iwd` 3.12 ships `/usr/lib/modules-load.d/pkcs8.conf` requesting `pkcs8_key_parser`. Because `kernel/crypto/asymmetric_keys/pkcs8_key_parser.ko` is now listed in `/usr/lib/modules/6.6.134+/modules.builtin`, `kmod`/`systemd-modules-load.service` treats it as built-in (`0` exit code), eliminating the boot-time `systemd-modules-load.service` failure seen in Boot 1/3 (`NOTES.md:1006`).
- Because `brcmfmac` is built-in (`CONFIG_BRCMFMAC=y`, `CONFIG_BRCMFMAC_SDIO=y`), it does not use `mac80211` software crypto (`brcmfmac` offloads CCMP/TKIP data-plane encryption to the BCM4354 firmware while `iwd` performs the 4-way EAPOL handshake in userspace over `AF_ALG`). Nothing is missing for WPA2-PSK.

---

## (b) `cfg80211.ieee80211_regdom=US` vs `brcmfmac`, `ccode=XV`, and `bcmdhd_clm_darcy.blob`

### 1. Does `bcmdhd_clm_darcy.blob` have a `US` entry?
**Yes (verified fact).**
Inspecting `recovery/9.1.1/vendor-firmware/bcmdhd_clm_darcy.blob` (`Nvidia.Darcy 1.29.15 ClmImport: 1.39.1 v2 18/11/02`) shows 12 country/locale definitions embedded in the CLM blob:
`AU`, `CN`, `DE`, `IN`, `JP`, `KR`, `Q2`, `RU`, `TW`, `US` (at offset `0x76c`, `US\x00\x00`, revision `0`), `XV`, and `XY`.
This matches NVIDIA's downstream DT `country_code_map` in `vendor/lineage-t210-foster/kernel-dts/tegra210-darcy-p2894-common.dtsi:365-600`, where `CC_US` (`:371-375`) maps `iso_abbrev = "US"` -> `custom_locale = "US"`, `custom_locale_rev = <0>`.

### 2. Does `brcmfmac` pass `cfg80211`'s `US` country code to the firmware?
**No (verified fact from `vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/cfg80211.c`).**

Here is the exact code path when `cfg80211.ieee80211_regdom=US` is on the kernel command line (`kernel/dts/darcy-system.dts:20`):
1. `regulatory_init_db()` (`vendor/linux/net/wireless/reg.c:4321-4323`, `late_initcall`) sees `ieee80211_regdom="US"` (`reg.c:91-93`) and calls `regulatory_hint_user("US", NL80211_USER_REG_HINT_USER)`.
2. `cfg80211` loads `regulatory.db` / `regulatory.db.p7s` from the initramfs (`scripts/12-make-payload.sh:84-88` packs `FIRMWARE` into `initramfs.cpio.gz` even for `--system`) and invokes `wiphy->reg_notifier` -> `brcmf_cfg80211_reg_notifier()` (`cfg80211.c:8240-8281`).
3. `brcmf_cfg80211_reg_notifier()` checks that `req->alpha2` is non-`"00"` and calls `brcmf_translate_country_code(ifp->drvr, req->alpha2, &ccreq)` (`cfg80211.c:8271`).
4. Inside `brcmf_translate_country_code()` (`cfg80211.c:7961-8014`):
   ```c
   country_codes = drvr->settings->country_codes;
   if (!country_codes) {
       if (brmcf_use_iso3166_ccode_fallback(drvr)) {
           brcmf_dbg(INFO, "No country codes configured for device, using ISO3166 code and 0 rev\n");
           memset(ccreq, 0, sizeof(*ccreq));
           ccreq->country_abbrev[0] = alpha2[0];
           ccreq->country_abbrev[1] = alpha2[1];
           ccreq->ccode[0] = alpha2[0];
           ccreq->ccode[1] = alpha2[1];
           return 0;
       }

       brcmf_dbg(INFO, "No country codes configured for device\n");
       return -EINVAL;
   }
   ```
   - `drvr->settings->country_codes` is populated by `brcmf_of_get_country_codes()` (`vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/of.c:26-78`) from the DT property `brcm,ccode-map` on the `wifi@1` node. In `kernel/dts/darcy.dts:221-227`, `wifi@1` has **no `brcm,ccode-map` property**, so `country_codes` is `NULL`.
   - `brmcf_use_iso3166_ccode_fallback(drvr)` (`cfg80211.c:7945-7959`) checks `drvr->settings->trivial_ccode_map` (only set by Apple ACPI in `acpi.c`, never by `of.c`) and then switches on `drvr->bus_if->chip`, which **only lists `BRCM_CC_43430_CHIP_ID`, `BRCM_CC_4345_CHIP_ID`, `BRCM_CC_4356_CHIP_ID`, and `BRCM_CC_43602_CHIP_ID` — NOT `BRCM_CC_4354_CHIP_ID` (`4354`)**!
5. Consequently, `brcmf_translate_country_code()` returns `-EINVAL`, and `brcmf_cfg80211_reg_notifier()` **returns early at `cfg80211.c:8273`** without sending the `"country"` iovar (`cfg80211.c:8275`) and without calling `brcmf_setup_wiphybands(cfg)` (`cfg80211.c:8280`). The BCM4354 firmware remains in `ccode=XV` (from `recovery/9.1.1/vendor-firmware/nvram_darcy_a00.txt:15`).

### 3. Does `cfg80211.ieee80211_regdom=US` make things worse than leaving the world domain?
**Yes — without `brcm,ccode-map` in DT, `cfg80211.ieee80211_regdom=US` creates an asynchronous race and regulatory split-brain between `cfg80211` and the BCM4354 firmware (verified fact):**

- During driver attach (`brcmf_cfg80211_attach()`, `cfg80211.c:8376-8400`), `brcmfmac` sets `wiphy->regulatory_flags |= REGULATORY_CUSTOM_REG`, calls `wiphy_apply_custom_regulatory(wiphy, &brcmf_regdom)` (`cfg80211.c:219-234`, which sets `chan->orig_flags = 0` on 2.4 GHz ch 1–14 and 5 GHz ch 34–165), registers the wiphy, and calls `brcmf_setup_wiphybands(cfg)` (`cfg80211.c:8400`).
- `brcmf_setup_wiphybands(cfg)` -> `brcmf_construct_chaninfo()` (`cfg80211.c:6996-7128`) queries the firmware's active `chanspecs` and `per_chan_info` (under `ccode=XV`) and sets `channel->flags` directly (marking firmware-unsupported channels `IEEE80211_CHAN_DISABLED` and firmware-passive channels `IEEE80211_CHAN_NO_IR`).
- When no user regdom is set (`NL80211_REGDOM_SET_BY_CORE`), `ignore_reg_update()` (`vendor/linux/net/wireless/reg.c:2100-2105`) returns `true` for `REGULATORY_CUSTOM_REG` wiphys, so `cfg80211` leaves the firmware's exact `brcmf_construct_chaninfo()` flags untouched.
- **However**, `ignore_reg_update()` returns **`false`** for `NL80211_REGDOM_SET_BY_USER` (`reg.c:2086-2123`), which is what `cfg80211.ieee80211_regdom=US` triggers!
- When `regulatory.db` finishes loading `US` after `brcmf_setup_wiphybands()` has run:
  1. `wiphy_update_regulatory(wiphy, NL80211_REGDOM_SET_BY_USER)` calls `handle_band()` -> `handle_channel()` (`reg.c:1934-2016`), which **resets `chan->flags` from `chan->orig_flags` (`brcmf_regdom`) ORed with the `US` rules from `regulatory.db`** (`reg.c:1783, 1945`), wiping out the channel/bandwidth/passive flags that `brcmf_construct_chaninfo()` read from the firmware!
  2. Next, `reg_call_notifier()` calls `brcmf_cfg80211_reg_notifier()`, which **supposedly** re-runs `brcmf_setup_wiphybands(cfg)` at `cfg80211.c:8280` to re-sync `chan->flags` with the firmware — **except it aborts at line 8273 because `brcmf_translate_country_code()` returned `-EINVAL`!**
  3. Result: `cfg80211` and `iwd` now believe 5 GHz channels (and HT40/VHT80 bandwidths) have `US` active-scan permissions, while the BCM4354 firmware is still enforcing `ccode=XV` (`WL_CHAN_PASSIVE` / `XV` channel set), which can cause active probe requests or join attempts on `XV`-restricted/passive channels to be rejected by the firmware.

### How to Fix (Two Clean Options)
1. **Option A (Recommended — make `US` actually work in both firmware and `cfg80211`):**
   Add `brcm,ccode-map` to `wifi@1` in `kernel/dts/darcy.dts:221-227` using the exact values from `vendor/lineage-t210-foster/kernel-dts/tegra210-darcy-p2894-common.dtsi:366-380`:
   ```dts
   wifi@1 {
       reg = <1>;
       compatible = "brcm,bcm4354-fmac", "brcm,bcm4329-fmac";
       interrupt-parent = <&gpio>;
       interrupts = <TEGRA_GPIO(H, 2) IRQ_TYPE_LEVEL_HIGH>;
       interrupt-names = "host-wake";
       brcm,ccode-map = "US-US-0", "XV-XV-0", "CA-Q2-0", "DE-DE-0", "GB-DE-0", "JP-JP-0", "AU-AU-0", "CN-CN-0", "IN-IN-0", "KR-KR-0", "RU-RU-0", "TW-US-0";
   };
   ```
   With `brcm,ccode-map` present in `darcy.dts`, `brcmf_translate_country_code()` translates `"US"` -> `ccode="US", rev=0`, sends the `"country"` iovar to the BCM4354 firmware (which loads the `US` `rev 0` rules from `bcmdhd_clm_darcy.blob`), and calls `brcmf_setup_wiphybands(cfg)` to sync `wiphy->bands` with the firmware's `US` channel list.
2. **Option B (Minimal — keep firmware's `ccode=XV` without split-brain):**
   Remove `cfg80211.ieee80211_regdom=US` from `kernel/dts/darcy-system.dts:20` so `cfg80211` stays in `NL80211_REGDOM_SET_BY_CORE` and preserves `brcmf_setup_wiphybands()`'s `ccode=XV` channel flags. (Under `XV`, 2.4 GHz ch 1–11 and standard 5 GHz channels still work for STA association, though 5 GHz scanning is passive until beacons are heard.)

---

## (c) `scripts/16-update-usb-disk.sh` Safety and Completeness

### 1. Does `make modules_install` + `rsync -a --delete` clean up the 6 promoted `.ko` files and update `modules.dep`?
**Yes (verified fact from `vendor/linux/scripts/Makefile.modinst`).**
-Even though `build/linux/` still contains stale object files from the previous `=m` build (`build/linux/crypto/{af_alg,algif_hash,algif_skcipher,des_generic,dh_generic,md5}.ko`, `build/linux/crypto/asymmetric_keys/pkcs8_key_parser.ko`, `build/linux/lib/crypto/{libdes,libmd5}.ko`), `vendor/linux/scripts/Makefile.modinst:17,43` reads **`$(MODORDER)` (`build/linux/modules.order`)**, *not* a filesystem glob of `*.ko`.
- Verified in `build/linux/modules.order` and `build/linux/modules.builtin`: none of those 9 modules appear in `modules.order`, and all 9 now appear in `modules.builtin`.
- `Makefile.modinst:62-63` copies `modules.order`, `modules.builtin`, and `modules.builtin.modinfo` into `$stage/usr/lib/modules/6.6.134+` and runs `$(CONFIG_SHELL) $(srctree)/scripts/depmod.sh $(DEPMOD) $(KERNELRELEASE)` (`depmod -b "$stage" 6.6.134+`), regenerating `modules.dep`, `modules.dep.bin`, `modules.builtin.bin`, and `modules.alias(.bin)` inside `$stage`.
- Finally, `scripts/16-update-usb-disk.sh:100-101` runs:
  ```bash
  sudo rsync -a --delete "$stage/usr/lib/modules/$release/" "$mnt/usr/lib/modules/$release/"
  ```
  Because of `--delete` and the trailing slashes on both paths, `rsync` deletes the 9 promoted `.ko` files from the SSD's `/usr/lib/modules/6.6.134+/kernel/` and replaces `modules.dep(.bin)` and `modules.builtin(.bin)` with the freshly generated ones.

### 2. Minor Edge Cases in `scripts/16-update-usb-disk.sh`
1. **Pre-mounted partition handling (`scripts/16-update-usb-disk.sh:55-68`):**
   If `/dev/$part` is already auto-mounted by the desktop session before `16-update-usb-disk.sh` starts, `udisksctl mount -b "/dev/$part"` exits non-zero (`AlreadyMounted`), failing the script under `set -e`. Checking `findmnt -rn -S "/dev/$part" -o TARGET` before calling `udisksctl mount` (as `14-install-system.sh:50-52` checks `MOUNTPOINT`) avoids a spurious failure if the user's file manager auto-mounts `darcy-root`.
2. **`/var/lib/iwd` directory permissions (`scripts/16-update-usb-disk.sh:105`):**
   In `build/rootfs.img`, `/var/lib/iwd` does not exist yet (verified via `debugfs`: `/var/lib/iwd: File not found`), because `iwd` creates `/var/lib/iwd` with mode `0700` on first start. `sudo install -d -m 700 "$mnt/var/lib/iwd"` in `16-update-usb-disk.sh:105` sets the exact `0700` permissions `iwd` expects, **provided `device-info/wifi` exists** when the script runs.

---

## (d) Ordering of Step 2 (`fastboot boot` recovery FIT) and Step 3 (`fastboot flash boot` system FIT)

### 1. Can the old FIT ever boot with the new modules (or vice versa) in the proposed sequence?
**No (verified fact).**
Trace of the proposed sequence:
1. Before Step 2, the SSD is unplugged while Shield is in fastboot; in Step 2, `fastboot boot build/boot-recovery.img` boots entirely into RAM (`initramfs.cpio.gz` from `12-make-payload.sh --recovery`) with the SSD still unplugged (`step3-review-brief.md:31`). It never mounts the SSD.
2. When `systemctl --reboot-argument=bootloader reboot` runs in Step 2, the kernel writes `"bootloader"` into `PMC_SCRATCH0` (`tegra-reboot` mode) and resets into TBOOT/CBoot fastboot mode (`NOTES.md:198`).
3. While the Shield sits idle in fastboot, the SSD is updated on the host via `16-update-usb-disk.sh`, moved back to the Shield, and `fastboot flash boot build/boot-system.img && fastboot reboot` flashes the new system FIT into eMMC `boot` (`LNX`) before rebooting.
4. Thus, at no point does the old `boot-system.img` boot against the updated SSD, nor does the new `boot-system.img` boot against the un-updated SSD.

### 2. Is Step 2 needed at all, or can you go straight to Step 3?
- **Depends on the current state of the Shield right now:**
  - If the Shield is **already running Boot 3 (`boot-system.img` from eMMC)** with no SSH and no local console keyboard login, you need a way to get it back into fastboot mode (`0955:fastboot`). Since you cannot run `systemctl --reboot-argument=bootloader reboot` without a shell, your only way into fastboot from a running Boot 3 is to unplug the USB SSD, wait ~5 seconds for the rootfs ext4 errors/panic (`panic=5` on cmdline) to reboot the board, and hold/enter fastboot via the USB-A recovery/fastboot keychord or CBoot menu.
  - **Once the Shield is in fastboot mode** (and the SSD is unplugged to plug into your host), **Step 2 is completely unnecessary** for installing Step 3: you can update the SSD on the host with `scripts/16-update-usb-disk.sh`, plug the SSD back into the Shield, and immediately run `fastboot flash boot build/boot-system.img && fastboot reboot`.
  - The only reason to run Step 2 while the SSD is on the host is if you specifically want to verify `systemctl --reboot-argument=bootloader reboot` over `adb shell` in the recovery RAM disk before flashing Step 3.

---

## (e) Anything Else That Will Stop Wi-Fi or SSH on the First Try

I verified the entire chain from kernel boot -> `brcmfmac` -> `iwd` -> `systemd-networkd` -> `sshd` in `build/rootfs.img`:

### 1. Verified Good in `build/rootfs.img`
- **Service enablement (verified via `debugfs` on `build/rootfs.img`):**
  `/etc/systemd/system/multi-user.target.wants/` contains symlinks for:
  - `iwd.service`
  - `systemd-networkd.service`
  - `sshd.service` (pre-enabled in the Arch Linux ARM base tarball even though `13-make-rootfs.sh:118` only explicitly runs `systemctl enable iwd.service bluetooth.service`).
- **Networkd DHCP config (verified in `scripts/13-make-rootfs.sh:89-96`):**
  `/etc/systemd/network/25-wl.network` matches `Name=wl*` (`wlan0` matches `wl*` since `net.ifnames=0` is not needed when matching `wl*`—whether `wlan0` stays `wlan0` or is renamed `wlan0`/`wlp*`, `wl*` matches both) and sets `DHCP=yes`.
- **Root SSH authorized key (verified in `scripts/13-make-rootfs.sh:104-110`):**
  `device-info/ssh/id_ed25519.pub` exists and is installed to `/root/.ssh/authorized_keys` (`0600`).
- **Firmware in initramfs (verified in `scripts/12-make-payload.sh:84-98`):**
  Both `--recovery` and `--system` pack `FIRMWARE` (`regulatory.db`, `regulatory.db.p7s`, `nvidia/tegra210/xusb.bin`) and `VENDOR_FIRMWARE` (`brcm/brcmfmac4354-sdio.{bin,txt,clm_blob}`) into `initramfs.cpio.gz`, so built-in `brcmfmac` (`=y`) and `cfg80211` (`=y`) always find their firmware even before switching root to the USB SSD.

### 2. Three Concrete Issues to Address Before Booting Step 3

1. **`device-info/wifi` does not exist yet (verified fact):**
   Running `ls -la device-info/` shows no `device-info/wifi` file. If you run `scripts/16-update-usb-disk.sh` without creating `device-info/wifi` (`SSID=...` and `PSK=...`) first, lines 104–110 will silently skip installing `/var/lib/iwd/<SSID>.psk`, and the Shield will boot without knowing what Wi-Fi network to join.
2. **`iwd` `.psk` profile filename encoding if your SSID has spaces or special characters (verified fact):**
   In `scripts/16-update-usb-disk.sh:85-91`:
   ```bash
   safe_ssid=$(printf '%s' "$SSID" | tr -cd 'A-Za-z0-9_-')
   ```
   In `iwd` (`src/storage.c` `storage_network_open()` / `storage_ssid_to_filename()`), `iwd` determines the network SSID **from the filename before `.psk`**, **not** from an `SSID=` key inside the file! Specifically:
   - If the SSID consists solely of `[A-Za-z0-9_-]`, the filename must be `<SSID>.psk`.
   - If the SSID contains spaces, dots, or any character outside `[A-Za-z0-9_-]` (for example `"My Home WiFi"` or `"Marcho.5G"`), `tr -cd 'A-Za-z0-9_-'` strips the space/dot to produce `MyHomeWiFi.psk` or `Marcho5G.psk`, which tells `iwd` to look for an AP literally named `"MyHomeWiFi"` or `"Marcho5G"`, so **it will never autoconnect to `"My Home WiFi"` or `"Marcho.5G"`!**
   - For any SSID containing characters outside `[A-Za-z0-9_-]`, `iwd` requires the filename to be `=<hex-encoded-utf8-ssid>.psk` (e.g., `=$(printf '%s' "$SSID" | xxd -p -c 256).psk`).
   - Quick fix for `scripts/16-update-usb-disk.sh:85-87` so it works for **any** SSID:
     ```bash
     if [[ "$SSID" =~ ^[A-Za-z0-9_-]+$ ]]; then
         psk_name="${SSID}.psk"
     else
         psk_name="=$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n').psk"
     fi
     ```
3. **`cfg80211.ieee80211_regdom=US` split-brain without `brcm,ccode-map` (verified fact, see Question (b)):**
   Either add `brcm,ccode-map = "US-US-0", "XV-XV-0", ...;` to `wifi@1` in `kernel/dts/darcy.dts:221-227` (and re-run `scripts/12-make-payload.sh --system` so `build/boot-system.img` has the updated DTB), or drop `cfg80211.ieee80211_regdom=US` from `kernel/dts/darcy-system.dts:20`.
