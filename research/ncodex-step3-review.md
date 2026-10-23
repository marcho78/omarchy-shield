# Step 3 Wi-Fi review

## Verdict

The kernel option set is sufficient for iwd 3.12 to start and for WPA2-PSK. No requested Kconfig symbol was dropped. There are, however, two changes I would make before running step 3:

1. **Required: fix the unmounted-disk path in `scripts/16-update-usb-disk.sh`.** With `set -euo pipefail` inherited from `scripts/lib.sh:2`, `mnt=$(findmnt ... | head -1)` at `scripts/16-update-usb-disk.sh:30` exits the whole script when the partition is not mounted. It never reaches the intended `udisksctl mount` branch.
2. **Recommended for reliable 5 GHz: add Darcy's firmware country translation to the Wi-Fi DT node.** `cfg80211.ieee80211_regdom=US` correctly sets cfg80211's host domain, but the present DT does not let brcmfmac translate that request for a BCM4354. Stock Darcy explicitly maps `US -> US, rev 0`, so this can be fixed without guessing.

The proposed kernel/modules handoff is operationally safe if the SSD remains detached while its same-release module tree is replaced and until the new FIT has been successfully flashed. It is not mechanically atomic; a distinct step-3 kernel release would make it intrinsically safe.

## A. iwd and Kconfig

### Verified: the effective config passes iwd 3.12's startup checks

iwd's `check_crypto()` tests AF_ALG HMAC-SHA1/MD5/SHA256, CMAC-AES, DES/3DES, AES, plus several warning-only facilities; it returns failure for the missing AF_ALG hash/skcipher primitives observed in the journal ([iwd 3.12 `src/main.c:273-402`](https://www.kernel.org/pub/linux/network/wireless/iwd-3.12.tar.xz)). The rebuilt effective configuration has:

- `CRYPTO_USER_API=y`, `CRYPTO_USER_API_HASH=y`, and `CRYPTO_USER_API_SKCIPHER=y` (`build/linux/.config:8831-8833`);
- AES, DES, CBC, ECB, CMAC, HMAC, MD5, SHA1, SHA256, and SHA512 all built in (`build/linux/.config:8737,8744,8760-8763,8786-8793`);
- `KEY_DH_OPERATIONS=y` (`build/linux/.config:8615`);
- the existing asymmetric-key stack plus `PKCS8_PRIVATE_KEY_PARSER=y` (`build/linux/.config:8879-8883`).

`scripts/11-build-kernel.sh:30-35` also explicitly rejects any requested `=y` fragment entry that does not survive `olddefconfig`. Thus there is no silent Kconfig drop here.

The dependency effects are expected:

- Both AF_ALG children select the hidden `CRYPTO_USER_API`; selecting them as built-ins promotes the parent from `m` to `y` (`vendor/linux/crypto/Kconfig:1234-1260`). `CRYPTO_USER_API_RNG` remains a module, so this does not promote every AF_ALG child.
- `KEY_DH_OPERATIONS` selects `CRYPTO_DH` and `CRYPTO_KDF800108_CTR`, which are now built in (`vendor/linux/security/keys/Kconfig:110-118`; `build/linux/.config:8725,8825`). DH is warning-only in iwd and is used for WPS, not ordinary WPA2-PSK.
- PKCS#8 depends on the already-built-in asymmetric public-key subtype and selects ASN.1/OID support (`vendor/linux/crypto/asymmetric_keys/Kconfig:37-45`). It is not needed for WPA2-Personal; it makes iwd's installed `pkcs8_key_parser` modules-load request clean.
- MD5 and DES select their normal library/algorithm prerequisites (`vendor/linux/crypto/Kconfig:458-465,885-890`).

`build/linux/modules.builtin` now records `af_alg`, `algif_hash`, `algif_skcipher`, `md5`, `des_generic`, `dh_generic`, and `pkcs8_key_parser` as built-ins. Consequently libkmod/systemd-modules-load can recognize the PKCS#8 parser as built in rather than looking for a `.ko`.

The only broader effect worth noting is the one stated by Kconfig itself: the AF_ALG hash/skcipher interfaces are deprecated, exposed to unprivileged userspace, and have had vulnerabilities (`vendor/linux/crypto/Kconfig:1237-1275`). iwd requires them, so enabling them is justified; there is no Darcy-specific side effect.

**Conclusion:** iwd should stay active and can join a normal WPA2-PSK/CCMP network. The BCM4354 firmware already probed and created `wlan0`, so the previously observed blocker was iwd's crypto check, not the radio. **UNCERTAIN:** hardware/firmware behavior has not yet been exercised with the new kernel. WPA3-SAE should not be used as the acceptance test: NVIDIA's firmware capability banner contains `mfp` but no `sae` or `sae_ext`; brcmfmac advertises SAE only from those capability flags (`vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/feature.c:37-48,228-250`; `cfg80211.c:7695-7712`). WPA2 is the appropriate first test.

## B. Regulatory domain, NVRAM, and CLM

### Verified: host-side US works, but the current driver does not send US to this firmware

Because cfg80211 is built in, `cfg80211.ieee80211_regdom=US` is a valid built-in module parameter. It replaces the default `00` (`vendor/linux/net/wireless/reg.c:276-281`) and is applied as a user regulatory hint during cfg80211's late initialization (`reg.c:4317-4329`). The signed regulatory database and signature are included in the FIT initramfs (`config.sh:66-73`; `scripts/12-make-payload.sh:49-60,84-98`). This correctly constrains Linux to US rules and eliminates dependence on Arch's failed `set-wireless-regdom` helper.

brcmfmac does have a regulatory notifier and, after translation, writes the firmware `country` iovar (`vendor/linux/drivers/net/wireless/broadcom/brcm80211/brcmfmac/cfg80211.c:8240-8280`). The translation is the catch:

- The current `wifi@1` node has no `brcm,ccode-map` or `brcm,ccode-map-trivial` (`kernel/dts/darcy.dts:221-227`).
- With no map, automatic ISO-code/revision-zero fallback is allowed only for chip IDs 43430, 4345, 4356, and 43602—not BCM4354 (`cfg80211.c:7945-7958`). Therefore the BCM4354 path returns `-EINVAL` before setting the firmware country (`cfg80211.c:7975-7988`).
- The mainline helper that rewrites NVRAM `ccode=XV` to `X2` applies only to EFI-provided NVRAM (`brcmfmac/firmware.c:464-518`), not Darcy's file. Thus the installed `ccode=XV, regrev=0` remains the firmware's initial setting.

There is strong board-specific evidence for the correct mapping: NVIDIA's downstream Darcy DT maps `US` to firmware locale `US`, revision `0` (`vendor/lineage-t210-foster/kernel-dts/tegra210-darcy-p2894-common.dtsi:365-375`) and names the same Darcy CLM blob at `:360-362`. The corresponding mainline property is:

```dts
brcm,ccode-map = "US-US-0";
```

The binding defines precisely that ISO-to-firmware-locale/revision format (`vendor/linux/Documentation/devicetree/bindings/net/wireless/brcm,bcm4329-fmac.yaml:85-100`). Prefer this explicit Darcy mapping over `brcm,ccode-map-trivial`, whose assumption would be wrong for several countries in NVIDIA's full table.

If firmware/CLM had no `US` locale, the `country` iovar would fail, brcmfmac would log `Firmware rejected country setting`, and the existing firmware country would remain; the interface is not torn down (`cfg80211.c:8271-8279`). Linux's host US domain would still apply, so usable channels would be the intersection of host and firmware restrictions. **UNCERTAIN:** how restrictive this exact firmware treats `XV`; the kernel source warns that `XV` can remove all 5 GHz channels (`brcmfmac/firmware.c:465-471`). NVIDIA's stock `US-US-0` mapping is good evidence that the supplied CLM does contain US.

**Recommendation: keep `cfg80211.ieee80211_regdom=US`, and add `US-US-0` to the Wi-Fi node before the final step-3 rebuild.** Dropping the parameter restores the restrictive world domain and does not improve firmware behavior. Without the DT mapping, 2.4 GHz channels 1-11 are likely to work, but a 5 GHz-only SSID is **UNCERTAIN** and is the avoidable first-try risk.

## C. `scripts/16-update-usb-disk.sh`

### Required correctness fix

The script is syntactically valid (`bash -n` passed), but its normal unmounted-device path is broken. `scripts/lib.sh:2` enables both `errexit` and `pipefail`. On an unmounted partition, `findmnt` returns nonzero, so the assignment/pipeline at `scripts/16-update-usb-disk.sh:30` terminates the script. Use a conditional or make absence non-fatal, for example conceptually:

```bash
mnt=$(findmnt -nro TARGET -S "$part" 2>/dev/null || true)
```

Track whether this script mounted the filesystem and only run `udisksctl unmount` in that case. As written, an already-mounted disk is unconditionally unmounted at line 40; this is surprising and may fail if it was mounted by another mechanism. A read-only existing mount will make rsync fail safely, rather than silently succeed.

### Verified-safe parts

- Resolving `/dev/disk/by-partlabel/darcy-root`, requiring a block device, walking to its parent with `PKNAME`, and requiring parent `TRAN=usb` (`:19-22`) prevents writes to the SHIELD and rejects an internal laptop disk in the expected topology. **UNCERTAIN edge case:** duplicate `darcy-root` labels among USB disks are not disambiguated. Before `sudo rsync`, print/verify the resolved device, model, serial, size, and mount point if this is intended as a reusable safety tool.
- `rsync` has trailing slashes on both source and destination, so `--delete` is scoped to exactly `/usr/lib/modules/$release/` (`:37-38`), not `/usr` or the filesystem root. It will remove any same-release out-of-tree/DKMS modules; none are expected on this fresh image.
- `modules_install` installs only objects listed by the current `modules.order` (`vendor/linux/scripts/Makefile.modinst:43-65`) and runs depmod after installation (`:127-135`). The current host has `depmod` and `build/linux/System.map`, so staging will contain fresh `modules.dep`, aliases, softdeps, and built-in metadata. For future robustness, add `depmod` to `need`: `vendor/linux/scripts/depmod.sh:20-25` merely warns and exits successfully when it is absent.
- The stale `build/linux/crypto/md5.ko`, `des_generic.ko`, and `af_alg.ko` are harmless. They are absent from the current `modules.order` and present in `modules.builtin`; `modules_install` will not copy them. The empty staging directory plus `rsync --delete` removes their obsolete copies from the SSD.
- `--chown=0:0` gives the installed tree the correct ownership, and `sync` precedes unmount.

Nothing else on the SSD must change for this kernel delta. The Image, DT, command line, and firmware initramfs live in the FIT; the complete matching module directory is the only kernel-owned SSD content. Existing iwd, networkd, sshd, firmware, and regulatory database files remain suitable. Replacing `modules.builtin*` is important because several former modules are now built in, and this script does that.

## D. Handoff ordering

The proposed order is safe under its stated invariant:

1. Step 2 boots normally, then `systemctl --reboot-argument=bootloader reboot` enters cboot's menu.
2. Remove the SSD before replacing its module tree. While it is attached to the laptop, the old FIT cannot mount the new modules.
3. If and only if the module update completes, flash the matching step-3 FIT while the SHIELD remains in the bootloader menu.
4. Reattach the SSD only after the flash succeeds, then boot.

Thus neither mismatched half is bootable in the intended physical sequence. It is not fully airtight against operator error, a failed/incorrect flash, or reattaching the SSD prematurely. `scripts/14-install-system.sh:28-32` validates the configured root but does not prove that the FIT and SSD module tree came from the same build, and both builds report `7.2.11-ga2de78ee6ed8`.

A simpler and safer operational order is to build and preserve a versioned copy of the complete step-3 boot image **before** leaving the working step-2 system, then enter the menu, detach/update the SSD, flash that already-verified image, and reconnect. This removes build time and shared-output ambiguity from the critical window. The strongest design is a distinct `LOCALVERSION` for step 3: old and new module directories can coexist, so either FIT loads only its own release. That is more robust, though it entails one more rebuild.

If `scripts/16` or flashing fails, keep the SSD detached. Retry the matching half or restore the old module tree; do not test-boot merely to diagnose the host-side failure.

## E. First-try Wi-Fi and SSH checklist

- Add the Darcy `US-US-0` mapping if the AP may be 5 GHz; otherwise this is the largest remaining Wi-Fi uncertainty.
- Use WPA2-PSK/CCMP for the first connection, not SAE-only WPA3. A WPA2/WPA3 transition SSID should fall back to WPA2, but **UNCERTAIN** until iwd reports the advertised AKMs.
- `iwctl station wlan0 connect "<SSID>"` is correct for a visible SSID and will prompt for/store the passphrase. A hidden network needs iwd's hidden-network path. Wait for DHCP before SSH.
- `scripts/13-make-rootfs.sh:145-153` gives every `wl*` interface networkd DHCP, and `:171-177` installs the root public key and disables password SSH. Read-only inspection of `build/rootfs.img` confirms `iwd.service`, `sshd.service`, `systemd-networkd.service`, and `systemd-resolved.service` are enabled.
- There is no demonstrated mDNS advertisement from the device. Obtain the address with `ip -4 addr show wlan0`, `networkctl status wlan0`, or the router's lease table, rather than assuming `darcy.local` works.
- The NVRAM MAC `00:90:4c:16:70:01` is a vendor placeholder. It does not by itself prevent association, but a duplicate on the same WLAN will cause confusing DHCP/ARP behavior. Replace it from NCT when that extraction is understood; for this test, ensure no other device is using it.
- After boot, check in order: `systemctl --failed`, `systemctl status iwd`, `iwctl station wlan0 show`, `networkctl status wlan0`, and `journalctl -b -u iwd -u systemd-networkd`; also inspect the kernel log for `Firmware rejected country setting` or CLM-load errors. Preserve this journal before making further changes.

Subject to the script mount fix and preferably the DT country map, there is no remaining known blocker to WPA2 association, DHCP, and key-only root SSH.
