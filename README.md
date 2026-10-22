# Omarchy on the NVIDIA SHIELD TV 2017

A reproducible path to running [Omarchy](https://omarchy.org) (Arch Linux and
Hyprland) natively on an NVIDIA SHIELD TV 2017, which uses the Tegra X1.

The approach:
1. NVIDIA's own bootloader (cboot) starts U-Boot.
2. U-Boot starts a mainline Linux kernel with a device tree written for this board.
3. The kernel boots Arch Linux ARM from a USB drive.
4. The community [`omarchy-arm`](https://github.com/alexisraitano-myffu/omarchy-arm)
   port installs Omarchy on top.

Android stays installed, so you can go back.

> **Status: work in progress.** Phase 0 (identify the device, build the safety
> net) is scripted and tested. Booting Linux is being brought up now. See
> `NOTES.md` for the research log.

## Supported hardware

Only the **SHIELD TV 2017, 16 GB** (retail P2897, board P2894, product name
`darcy`). The scripts check this and refuse to touch anything else.

The 2015 models (`foster`) and the 2019 models (`mdarcy`, `sif`, Tegra X1+) are
different boards and are not covered.

## What you need

- An x86_64 Arch-based Linux host. Tested on Omarchy 4.5.
- A USB-A male-to-male cable, plus a USB-C to USB-A adapter if your computer only
  has USB-C. A plain USB-A-to-C phone cable will not work, because your computer
  has to be the host end.
- A USB 3 SSD or flash drive, 64 GB or more. It will be erased.
- A SHIELD controller with a USB cable, for the bootloader menu. Plug it into
  the USB port **near** HDMI; the computer goes in the port **far** from HDMI.
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

    scripts/05-build-u-boot.sh    # pinned LineageOS U-Boot + patches/u-boot/
    scripts/06-make-bootimg.sh    # -> build/boot-uboot.img

cboot starts U-Boot as if it were the kernel of an Android boot image. U-Boot
reads what cboot handed over (memory map, HDMI framebuffer, ramdisk, board
revision) and shows it on the TV. Given a payload, it then boots it.

For the design, see "Boot chain design" in `NOTES.md`.

### Next (not scripted yet)

1. Unlock the bootloader. This **erases Android user data**.
2. First test: `fastboot boot build/boot-uboot.img`, then read U-Boot's report
   on the TV.
3. Bring up the mainline device tree and kernel, and build the FIT payload.
4. Put Arch Linux ARM on USB.
5. Install `omarchy-arm`.

## Layout

| Path | What |
|---|---|
| `config.sh` | Every pinned version, commit and checksum |
| `scripts/` | Numbered steps; `lib.sh` holds shared helpers |
| `tools/nvblob.py` | Lists and extracts NVIDIA `NVIDIA__BLOB__V2` bootloader packages |
| `patches/u-boot/` | Our U-Boot board support for darcy (target `p2894`) |
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
