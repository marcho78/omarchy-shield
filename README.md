# Omarchy on the NVIDIA SHIELD TV 2017

A reproducible path to running [Omarchy](https://omarchy.org) (Arch Linux and
Hyprland) natively on an NVIDIA SHIELD TV 2017, which uses the Tegra X1.

The approach:
1. NVIDIA's own bootloader (cboot) starts U-Boot.
2. U-Boot starts a mainline Linux kernel with a device tree written for this board.
3. The kernel boots Arch Linux ARM from the SHIELD's internal eMMC.
4. The community [`omarchy-arm`](https://github.com/alexisraitano-myffu/omarchy-arm)
   port installs Omarchy on top.

Android stays installed, so you can go back.

> **Status: work in progress.**
> - **Done:** the boot chain is scripted and tested. cboot starts U-Boot from
>   the recovery slot, and U-Boot starts mainline Linux, whose console stays
>   on HDMI. Linux drives USB, Ethernet, Wi-Fi and Bluetooth, with NVIDIA's
>   firmware taken from the recovery image.
> - **Next:** Arch Linux ARM on the internal eMMC, then Omarchy.
>
> `NOTES.md` is the research log.

## Supported hardware

Only the **SHIELD TV 2017, 16 GB** (retail P2897, board P2894, product name
`darcy`). The scripts check this and refuse to touch anything else.

The 2015 models (`foster`) and the 2019 models (`mdarcy`, `sif`, Tegra X1+) are
different boards and are not covered.

## What you need

- An x86_64 Arch-based Linux host. Tested on Omarchy 4.5.
- A USB-A male-to-male cable, plus a USB-C to USB-A adapter if your computer only
  has USB-C. A plain USB-A-to-C phone cable will not work, because your computer
  has to be the host end. This was confirmed on an Intel T2 MacBook: with that
  cable the laptop sees no USB device at all.
- A USB keyboard or a SHIELD controller with a USB cable, for the bootloader
  menu (it has no Bluetooth). Plug it into the USB port **near** HDMI; the
  computer goes in the port **far** from HDMI. A USB keyboard (arrow keys +
  Enter) is confirmed to work on darcy; a mouse does not drive the menu.
- A free NVIDIA developer account, to download the stock recovery image.

## Safety rules

- **Unlocking the bootloader erases Android's apps, accounts and settings.**
  Android itself stays, and the recovery image restores it completely.
- **Only ever flash `boot` or `recovery`.** Never `dtb`, `staging`/blob, BCT,
  the bootloader, TOS, EKS or the partition table. A bad DTB has hard-bricked
  Shields before.
- **Use the 2017 recovery image at the same or a newer version** than the one
  your SHIELD runs. Never use an older one, and never one meant for another model.
- **Never relock the bootloader** while a custom image is installed.

## Steps

Every script is safe to re-run. Unless a step says otherwise, nothing on the
SHIELD changes.

### 0. Host tools

    scripts/00-host-setup.sh

### 1. Let the computer talk to the SHIELD

On the SHIELD:
1. Go to Settings → Device Preferences → About and press **Build** 7 times.
2. Go to Developer options and turn on **Network debugging**.

Then:

    scripts/01-find-shield.sh           # prints the SHIELD's IP address
    scripts/02-collect-device-info.sh   # read-only snapshot into device-info/

Approve "Allow network debugging?" on the TV when it appears. Check
`device-info/summary.txt`:
- `product` must be `darcy`.
- `SHIELD version` tells you which recovery image to download.
- `verified boot: green` means the bootloader is still locked.

### 2. Safety net: NVIDIA's recovery image

1. At <https://developer.nvidia.com/tools-downloads>, search "SHIELD Android
   TV 2017 Recovery".
2. Download the **Recovery OS Image** that matches your SHIELD version (pinned in
   `config.sh`). Save it in `~/Downloads`.
3. Run:

       scripts/04-unpack-recovery.sh

This verifies the checksum, unpacks the image, splits the bootloader package
and decompiles the board device trees. To restore stock Android later, use
NVIDIA's `flash-all.sh` from inside `recovery/<version>/`.

### 3. Sources

    scripts/03-fetch-sources.sh

This fetches NVIDIA's downstream darcy device trees and `omarchy-arm`, at the
commits pinned in `config.sh`.

### 4. Boot chain: U-Boot

    scripts/05-build-u-boot.sh            # pinned LineageOS U-Boot + patches/u-boot/
    scripts/06-make-bootimg.sh --probe    # -> build/boot-uboot-probe.img

cboot starts U-Boot as if it were the kernel of an Android boot image. U-Boot
reads what cboot handed over (memory map, HDMI framebuffer, ramdisk, board
revision) and shows it on the TV. Given a FIT payload, it then boots it.

The `--probe` image carries a dummy ramdisk with a known CRC32. U-Boot's
report shows where cboot put it, and whether it arrived intact.

`05` also checks the safety-critical settings on every build: `bootcmd`,
environment never saved, no GPU/VPR writes, no networking/EFI/storage writes.

For the design, see "Boot chain design" in `NOTES.md`.

### 5. USB and the bootloader

1. Connect the computer to the SHIELD's USB port **farthest from HDMI** with a
   USB-A male-to-male cable. Use a hub or adapter if the computer only has
   USB-C.
2. Accept "Allow USB debugging?" on the TV. The remote works for this.
3. Run:

       scripts/07-check-fastboot.sh

This reboots into the bootloader, checks fastboot over USB, records the lock
state and board revision, and reboots back. It changes nothing.
`device-info/fastboot.txt` should name `tegra210-darcy-p2894-0050-a08-00.dtb`.

### 6. Unlock the bootloader (erases Android user data)

    CONFIRM_UNLOCK=yes scripts/08-unlock-bootloader.sh

The bootloader asks for confirmation on the TV. The bootloader menu has no
Bluetooth, so plug a USB keyboard (arrow keys + Enter, confirmed on darcy) or a
SHIELD controller with a USB cable into the port **near** HDMI. Check it first
with `scripts/07-check-fastboot.sh --stay`: the arrow keys must move the
highlight, and Enter on "Continue" boots Android. Afterwards, finish Android setup and turn debugging back on. Then
`scripts/07` should report `unlocked: yes`.

### 7. Run U-Boot (recovery slot)

darcy's bootloader freezes on `fastboot boot`, so test images go into the
recovery partition. Booting Android in between would put the stock recovery
back (`vendor_flash_recovery`).

    scripts/07-check-fastboot.sh --stay       # into the bootloader menu
    CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh build/boot-uboot-probe.img
    scripts/10-watch-boot-outcome.sh          # optional: how the SHIELD comes back

Choose "Boot recovery kernel" in the menu. U-Boot's report appears on the TV.
The ramdisk CRC32 should equal `build/probe-ramdisk.crc32`, which shows U-Boot
left the payload intact. If U-Boot finds no framebuffer, it reboots into the
bootloader menu instead, and `scripts/10` reports `bootloader`.

`CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh --restore` puts the stock
recovery back.

### 8. First Linux payload

    scripts/11-build-kernel.sh    # pinned Linux, Tegra-only defconfig + kernel/darcy.config
    scripts/12-make-payload.sh    # FIT: kernel + kernel/dts/darcy.dts + tiny initramfs
    CONFIRM_FLASH=yes scripts/09-boot-via-recovery.sh build/boot-uboot-darcy.img

Choose "Boot recovery kernel" again. U-Boot boots the FIT, and the kernel's
console appears on the TV through the framebuffer U-Boot hands over: four
penguins, then the kernel log. `/init` (`tools/darcy-init.c`) reports what
Linux sees.

Then the SHIELD comes back by itself, even if Linux lost the screen. Any of
three things resets it:
- `/init` reboots into the recovery slot after a minute.
- A kernel panic resets the board after 10 s.
- If Linux hangs, the watchdog U-Boot armed resets the board after 150 s
  (`darcy_watchdog` in U-Boot's environment).

Each time, cboot starts the recovery slot again. U-Boot then shows the end
of the kernel's log, read from RAM (ramoops), instead of booting.
Photograph it. After 60 s (`darcy_log_secs`) U-Boot reboots into the
bootloader menu by itself, so the next image can be flashed straight away
with `scripts/09`, without going through Android.

### Next (not scripted yet)

1. Put Arch Linux ARM on the internal eMMC.
2. Extend the device tree: HDMI through tegra-drm, GPU (nouveau), audio,
   fan.
3. Install `omarchy-arm`.

## Layout

| Path | What |
|---|---|
| `config.sh` | Every pinned version, commit and checksum |
| `scripts/` | Numbered steps; `lib.sh` holds shared helpers |
| `tools/nvblob.py` | Lists and extracts NVIDIA `NVIDIA__BLOB__V2` bootloader packages |
| `patches/u-boot/` | Our U-Boot board support for darcy (target `p2894`) |
| `kernel/` | Kernel config fragment, our darcy device tree, the FIT description |
| `tools/darcy-init.c` | The first payload's `/init` |
| `build/` | Build output (git-ignored) |
| `NOTES.md` | Research log: findings, decisions, sources |
| `research/` | Brainstorms and background |
| `device-info/` | Your device snapshot (git-ignored; contains serial numbers) |
| `recovery/` | Your unpacked recovery image (git-ignored; NVIDIA's, not redistributable) |
| `vendor/` | Fetched third-party sources (git-ignored) |

## Credits

- The NVIDIA darcy device tree in mainline Linux (Mark Zhang and Thierry Reding).
- archeYR's mainline port for the 2015 SHIELD
  ([postmarketOS](https://wiki.postmarketos.org/wiki/Nvidia_SHIELD_TV_2015_/_2015_Pro_/_2017_Pro_(nvidia-foster))).
- The LineageOS SHIELD maintainers, for the U-Boot chainload approach and the
  mirrored NVIDIA sources.
- The `omarchy-arm` contributors.
