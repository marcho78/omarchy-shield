# Review: step 3 (Wi-Fi) for the installed system on darcy

**Verdict up front.** The kernel option set is right and verified effective
(all seven `=y` in `build/linux/.config`, and `scripts/11`'s post-merge
assertion at `scripts/11-build-kernel.sh:44-49` guarantees nothing was
silently dropped). The regdom parameter is well-designed and will actually
apply — `regulatory.db` is in the system initramfs — but note that
**brcmfmac will ignore it** on this board (no `brcm,ccode-map`, and the
4354 is not in the ISO-3166 fallback list), so it only sets the *kernel's*
rules. `scripts/16` is sound; three small nits. The ordering has one
structural weakness — the release string is identical across builds
(`7.2.11-ga2de78ee6ed8` comes from `vendor/linux`'s git, and the config
fragment lives outside that tree), so a mismatched FIT/modules pair boots
*silently*; make builds distinguishable if you want failure to be loud.
And one first-try blocker worth double-checking before the TV session:
the root console password (present, but which password?). Details,
verified vs guess, below.

---

## a) Do the options make iwd 3.12 start and join WPA2-PSK?

**Yes — verified end to end:**

- `build/linux/.config` now has `CRYPTO_USER_API=y`,
  `CRYPTO_USER_API_HASH=y`, `CRYPTO_USER_API_SKCIPHER=y`,
  `KEY_DH_OPERATIONS=y`, `CRYPTO_MD5=y`, `CRYPTO_DES=y`,
  `CONFIG_PKCS8_PRIVATE_KEY_PARSER=y`, plus the previously-`=y` ECB, CBC,
  SHA1/256/512, AES, CMAC, HMAC — every name on iwd's exit list from the
  journal. `CRYPTO_USER_API_ENABLE_OBSOLETE=y` is still set (needed for
  md5/des over AF_ALG; keep it).
- Nothing was silently dropped: `scripts/11` merges the fragment then
  **dies if any `=y` line is missing** from the result
  (`scripts/11-build-kernel.sh:44-49`), and the build ran through.
- For WPA2-PSK specifically, iwd's kernel needs are HMAC-SHA1 (PRF/PBKDF2)
  and AES/DES-family via AF_ALG — all `=y`. SAE (WPA3) is also covered:
  `KEY_DH_OPERATIONS=y` pulled `CRYPTO_DH=y`, `CRYPTO_KDF800108_CTR=y`,
  `CRYPTO_KPP=y` (selects, `security/keys/Kconfig:110-113`), and
  `CRYPTO_ECC/ECDH` were already `=y` — P-256 (SAE group 19) is in
  `crypto/ecc.c`. Verified in `.config`, not guess.

**Newly pulled in / changed, all harmless:**

- `PKCS8_PRIVATE_KEY_PARSER=y` selects `ASYMMETRIC_KEY_TYPE`,
  `X509_CERTIFICATE_PARSER`, `PKCS7_MESSAGE_PARSER` (all `=y` now) —
  a little extra built-in code; the boot image was 11.8 MB against the
  25.5 MiB cap, so size is a non-issue.
- `CRYPTO_USER_API` `=m`→`=y`: af_alg is now built in and registers at
  boot; nothing else consumes it. The old `af_alg.ko`/`md5.ko`/
  `des_generic.ko`/`libdes.ko`/`libmd5.ko` on the SSD are removed by
  `scripts/16`'s `--delete` (see c).
- Stale `md5.ko`, `des_generic.ko`, `libdes.ko`, `libmd5.ko` do remain in
  `build/linux/` from the `=m` days (verified by `find`), but they are
  **not in `modules.order`** (verified — the only "des" hit is
  `typec_displayport.o`), so `modules_install` never stages them; they are
  dead weight in the build dir only.

## b) `cfg80211.ieee80211_regdom=US` with brcmfmac, ccode=XV

**It will genuinely apply — because the regulatory db is in the
initramfs.** The parameter is consumed in
`net/wireless/reg.c:4321-4323` by `regulatory_init_db()`, which is a
**`late_initcall`** (`reg.c:4326-4327`, `#ifndef MODULE` — CFG80211 is
`=y`). Initcalls run before the real root mounts, so the only firmware
source at that moment is the initramfs — and `scripts/12` puts
`regulatory.db` + `regulatory.db.p7s` into *every* payload's initramfs
(`config.sh:71-73`, the `FIRMWARE` list feeds both payload types,
`scripts/12-make-payload.sh:49-68`). So the US user hint resolves against
the signed db instead of falling back to the world domain
(`reg_query_database()` → `query_regdb_file()`, `reg.c:1111-1116`).
Verified; not a guess.

**But brcmfmac will not pass it to the firmware.** The reg notifier
`brcmf_cfg80211_reg_notifier` (`.../brcmfmac/cfg80211.c:8240-8284`)
translates the alpha2 via `brcmf_translate_country_code`
(`cfg80211.c:7953-8010`): with no `brcm,ccode-map` in our DT
(`darcy.dts:221-227` has none) it falls back to the ISO-3166 pass-through
only for chips 43430/4345/4356/43602 (`cfg80211.c:7945-7957`) — **the
4354 is not in that list**, so translation returns `-EINVAL` and the
notifier silently does nothing (a TRACE-level debug only). The firmware
keeps whatever the NVRAM set at init (`ccode=XV`, NVIDIA's world-wide
code). Verified from the driver source.

**"What if the CLM blob has no US entry?"** — moot in this configuration:
the CLM is never queried for US, because the translation fails before any
`country` iovar is set. (If you later add `brcm,ccode-map = "US-US"` to
the wifi node, then the firmware would be asked, and a rejection would
just log "Firmware rejected country setting", `cfg80211.c:8275-8278` —
still harmless.)

**Keep or drop: keep.** Effects: the kernel-side rules become US (active
scan on 5 GHz non-DFS, sane power caps), the journal's
`set-wireless-regdom failed` systemd noise becomes moot, and country IEs
from the AP now intersect instead of overriding (`__reg_process_hint_user`,
`reg.c:2703-2705` — normal). Worst case is none: the firmware's own
world/XV rules can only be *stricter* than the kernel's US rules, and for
a 2.4 GHz US network even world rules suffice (ch 1–11 active). The one
scenario where US is *narrower* than world is EU ch 12/13 — irrelevant
for a US network, and you chose `WIFI_COUNTRY=US`.

## c) `scripts/16-update-usb-disk.sh`

**Safe and essentially complete.** Verified points:

- PARTLABEL lookup + `lsblk -no PKNAME` + `TRAN == usb` guard is right,
  and since the SHIELD's eMMC is never attached to this laptop, the
  darcy-root partlabel can only be the USB SSD.
- `make modules_install INSTALL_MOD_STRIP=1` into `build/modules` runs
  `depmod` against the staging tree, so `modules.dep/.alias/.builtin` all
  ship with the modules — nothing to re-run on the device.
- `rsync -a --delete --chown=0:0 "$stage/.../$release/" "$mnt/.../$release/"`
  with matching trailing slashes mirrors staging over the SSD's copy:
  the stale `md5.ko`/`des_generic.ko`/`af_alg.ko`/`libdes.ko`/`libmd5.ko`
  from the `=m` days are deleted, ownership is forced to root (necessary —
  `-a` alone would preserve the build user's uid under sudo), and stripped
  modules land. Correct scope: only `usr/lib/modules/$release/` is
  touched, journal and everything else preserved.
- Mount handling via `findmnt`/`udisksctl` is fine for a desktop session.

Nits (none blocking):

1. `modules_install` also creates a `source` symlink next to `build`; the
   script removes only `build` (`scripts/16` line `rm -f .../build`), so a
   dangling `source` symlink lands on the SSD. Cosmetic.
2. If the disk was mounted by something else read-only, rsync fails late
   rather than with a clear message; a `findmnt -nro OPTIONS` grep for `ro`
   would make the failure obvious. Nice-to-have.
3. There is no post-copy verification that the SSD's release dir matches
   the staging one (a `diff -r` would be cheap); the real protection is
   procedural — see (d).

**Does anything else on the SSD have to change with the kernel? No** —
verified: the system FIT's initramfs carries firmware only (no modules,
`scripts/12`), there is no dkms/mkinitcpio hooking the kernel, and the
boot FIT itself is flashed separately (`scripts/14`). Only the pairing
discipline matters (d).

## d) Ordering: never mix old FIT with new modules (or vice versa)

The sequence is correct as far as it goes — and the clean reboot into the
menu in step 1 also **stops the watchdog** (systemd holds `/dev/watchdog0`
with `RuntimeWatchdogSec=60`; closing it stops the WDT since
`WATCHDOG_NOWAYOUT` is off, and U-Boot re-arms only right before starting
a kernel, `board_quiesce_devices`), so the menu window is not under a
150 s timer while the SSD is on the laptop. The flash itself is done
while the SHIELD sits safely in the menu with the SSD unplugged, so
neither half can boot in the mixed state *during* the sequence.

The structural weakness: **both kernels have the same release string.**
`kernel.release` is `7.2.11-ga2de78ee6ed8`, which `scripts/setlocalversion`
derives from `vendor/linux`'s git state — and step 3's changes live in
`kernel/darcy.config` (outside that tree), so the hash doesn't move. With
`MODVERSIONS` off, module loading checks only the vermagic string, so a
mismatched pair *loads* and runs — the exact silent hazard. For this
particular step the delta is crypto-only and a mixed pair would actually
limp along, but the next kernel bump may not be so lucky. Two cheap
hardenings, either one sufficient:

1. **Make each build's release unique**: have `scripts/11` write
   `build/linux/localversion05` with a build serial (`+s3`, or a content
   hash of `darcy.config` + the Image). A mismatched pair then fails
   loudly (modules for `7.2.11-...+s3` simply don't exist for the old
   kernel's `7.2.11-...+s2`).
2. Or at least have `scripts/12 --system` embed the release into the FIT
   report U-Boot prints, so a photo of the menu proves which kernel is on
   the eMMC before the SSD goes back in.

**Is there a simpler sequence?** For step 3 itself, no — it's already the
minimum dance given no display-independent access yet. But once Wi-Fi and
SSH work, the whole menu/unplug ritual disappears: kernel updates can go
over SSH (build on the laptop, `rsync` the modules, `dd` the new boot
image to `/dev/mmcblk0p18` — the LNX partition — from the running
system, then reboot). That stays within the "flash only boot/recovery"
rule; keep the recovery-slot test payload as the fallback and never
interrupt the `dd`.

## e) Anything else that will stop Wi-Fi or SSH on the first try

Checked against the built image (read-only `debugfs` on
`build/rootfs.img` — the same image generation as the SSD's):

- **Services all enabled**: `/etc/systemd/system/multi-user.target.wants/`
  contains `iwd.service` (from `scripts/13:118`), `sshd.service`,
  `systemd-networkd.service` (Arch ARM base), and sysinit wants
  `systemd-resolved.service` + `systemd-timesyncd.service` (so DNS works
  and the clock self-heals once Wi-Fi is up). `/etc/resolv.conf` is the
  resolved symlink. `wl.network` matches `Name=wl*` with DHCP
  (`scripts/13:146-153`). Verified.
- **The console password is the one thing to confirm before the TV
  session.** `/etc/shadow` in the image has a real yescrypt hash for root
  (verified) — Arch ARM's default. The plan's step 4 types
  `iwctl … connect` on the TV as root; if nobody remembers which default
  that hash corresponds to, step 4 stalls. Two hedges: (a) while the SSD
  is already mounted on the laptop for `scripts/16`, also drop
  `/var/lib/iwd/<SSID>.psk` (same format `scripts/13:155-163` writes) so
  the first boot joins by itself; or (b) verify the password once on the
  step-2 boot before starting step 3.
- **iwd's runtime needs are otherwise met**: firmware loads from the
  initramfs (proven — wlan0 came up in every boot), the crypto interface
  now exists (a), machine-id is generated on first boot (image ships it
  empty), and iwd 3.12 starts once its option check passes.
- **Scanning**: expect firmware-side world rules (`ccode=XV`) regardless
  of the kernel regdom (b). 2.4 GHz networks associate normally; if the
  target AP is 5 GHz, prefer a non-DFS SSID first — if a DFS-only network
  is a must, that is the point where adding `brcm,ccode-map` to the wifi
  node (and trusting the CLM) becomes worth trying.
- **SSH path**: `PermitRootLogin` is Arch's default `prohibit-password`
  and `authorized_keys` is installed (`scripts/13:171-172`), sshd enabled
  (above) — key login as root will work; you'll SSH by IP (mDNS/`nss-myhostname`
  not configured — don't promise a name).
- **Minor, worth knowing**: the MAC is still the NVRAM placeholder
  (`00:90:4c:16:70:01`) — fine for DHCP; two SHIELDs on one LAN would
  collide (not today's problem). The wrong clock (2026-10-18) doesn't
  affect WPA2 or SSH.
- One procedural reminder for the menu session: the still-armed-watchdog
  caveat from the earlier review doesn't apply here (the reboot into the
  menu stops it cleanly), but if you *power-cycle* into the menu instead,
  arm nothing — just don't start a kernel before the SSD is back.

### TL;DR

- (a) Option set verified effective and complete for WPA2 (and WPA3/SAE);
  nothing silently dropped; pulled-in extras harmless.
- (b) Keep the regdom param — it applies because `regulatory.db` ships in
  the initramfs (late_initcall timing verified) — but know that brcmfmac
  ignores it on this board (no `ccode-map`, 4354 not in the fallback list,
  `brcmfmac/cfg80211.c:7945-7990`), so it only relaxes the kernel's rules.
- (c) `scripts/16` is safe and complete for its scope; nits: dangling
  `source` symlink, no ro-mount pre-check, no post-copy diff. Nothing else
  on the SSD is kernel-coupled.
- (d) Sequence works; make kernel builds uniquely versioned (localversion
  serial) so a mixed FIT/modules pair can never boot silently — the
  release string is currently identical across builds. Simpler future:
  updates over SSH with `dd` to LNX.
- (e) Everything service-side is verified enabled; the one open item is
  knowing the root console password (hash present, default unconfirmed) —
  hedge by pre-seeding the iwd `.psk` while the SSD is mounted for
  `scripts/16`, and try a 2.4 GHz network first.
