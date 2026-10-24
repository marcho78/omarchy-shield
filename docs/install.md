# Install

The whole path, from a stock SHIELD to Omarchy on the TV. Every step is a
script, and every version, commit and checksum is pinned in `config.sh`.

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
  Android itself stays. The recovery image reinstalls stock Android if
  needed, but can't bring back what the unlock erased.
- **Only ever flash `boot` or `recovery`**, plus `userdata` for the eMMC
  option (step 10). Never `dtb`, `staging`/blob, BCT,
  the bootloader, TOS, EKS or the partition table. A bad DTB has hard-bricked
  Shields before.
- **Use the 2017 recovery image at the same or a newer version** than the one
  your SHIELD runs. Never use an older one, and never one meant for another model.
- **Never relock the bootloader** while a custom image is installed.

## Steps

The scripts can be run again. Unless a step says otherwise, nothing on the
SHIELD changes. The steps that flash or erase ask first: `CONFIRM_…=yes`,
or the disk's name.

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

### 9. Root filesystem

    scripts/13-make-rootfs.sh             # build/rootfs.img and its sparse form, build/rootfs.simg
    scripts/12-make-payload.sh --system   # build/boot-uboot-darcy-system.img

`scripts/13` builds the system without root, in a user namespace (your
`/etc/subuid` range), running Arch Linux ARM's own `pacman` through QEMU.
- **The base** is Arch Linux ARM's signed aarch64 image, fully upgraded,
  with Wi-Fi (`iwd`), Bluetooth (`bluez`), `sudo`, and the kernel's modules.
- **NVIDIA's Wi-Fi and Bluetooth firmware** goes in under darcy's
  board-specific names.
- **SSH** takes a key made for the SHIELD, `device-info/ssh/id_ed25519`;
  passwords are refused over the network. On the TV, Arch Linux ARM's
  default root and alarm logins (from its installation notes) work until
  `scripts/22` locks them (step 13).
- **Wi-Fi without the TV:** put two lines in `device-info/wifi` before the
  build, `SSID=...` and `PASSPHRASE=...`, and the SHIELD joins that network
  by itself. Otherwise, join from the TV with `iwctl`.

The system payload boots that filesystem from where `config.sh`
`SYSTEM_ROOT` says it is. U-Boot boots it again after a normal reboot, and
stops at its log (then fastboot) only after a panic or a watchdog reset.

### 10. Install

The root filesystem goes on a USB disk, `SYSTEM_ROOT=PARTLABEL=darcy-root`
(the default), and Android's partitions stay as they are:

1. Plug the disk into the computer and write it. This **erases the disk**:

       sudo scripts/15-write-usb-disk.sh /dev/sdX

   It only takes a whole, unmounted USB disk, and asks you to type its name
   first.
2. Plug the disk into the SHIELD, through a hub on the port **near** HDMI (the
   keyboard can share the hub). Get to the bootloader menu, then:

       CONFIRM_FLASH=yes scripts/14-install-system.sh

   This puts U-Boot and the system into the boot partition, so the SHIELD
   starts Linux from then on. Android's system and data stay. To go back,
   `CONFIRM_FLASH=yes scripts/14-install-system.sh --restore` puts NVIDIA's
   boot partition back.

Alternatively, `SYSTEM_ROOT=PARTLABEL=UDA` puts the root filesystem on the
eMMC: `scripts/14` then writes it over Android's user data too. Android must
not start again while Linux is there, because it would offer to wipe it.

### 11. Updates without the TV

Once the installed system answers SSH, a new build goes on over the network
and the USB cable, with nothing to press:

    scripts/11-build-kernel.sh            # when the kernel changed
    scripts/12-make-payload.sh --system   # build/boot-uboot-darcy-system.img
    CONFIRM_FLASH=yes scripts/17-update-system.sh <the SHIELD's address>

`scripts/17` copies the kernel's modules over SSH when the kernel changed
(or with `--modules`). It then reboots the SHIELD into its bootloader,
flashes the boot image as soon as fastboot appears, reboots into it, and
checks that the new kernel runs. The computer must be on the SHIELD's USB
port far from HDMI.

Files of the installed system that this repository keeps under `rootfs/`
(the thermal guard, for one) go on the same way, without a reboot:

    scripts/18-update-files.sh <the SHIELD's address>

`scripts/13` puts the same files in a new root filesystem.

With the USB disk plugged into the computer instead,
`scripts/16-update-usb-disk.sh` puts the kernel's modules on it in place.
Flash the matching boot image with it (`scripts/12 --system`, then
`scripts/14`), and boot neither half alone.

Once the system is up, the TV console shows only critical kernel messages.
To see them all again until the next boot, run this on the SHIELD:
`echo Y > /sys/module/printk/parameters/ignore_loglevel`.

### 12. Mesa for the GPU

Arch Linux ARM's Mesa crashes every OpenGL program on Tegra on its first
draw (`NOTES.md`, "B1"). `scripts/19` builds the same release with
upstream's fix and our further tegra driver fixes (`patches/mesa/`) on the
SHIELD itself, in about 20 minutes, and puts it in place of `mesa`:

    scripts/19-build-mesa.sh <the SHIELD's address>

With `--no-install` it stops after the build, so the package can be tried
from its build tree first. `pacman -S mesa` brings Arch Linux ARM's back.
nouveau loads at boot. A system an older `scripts/13` made has
`/etc/modprobe.d/20-darcy-nouveau.conf`, which blocks it: delete that file.
Besides `patches/linux/0001`, without which the GPU doesn't start at all,
the kernel needs `0004` and `0005`. Without them, nouveau rejects command
batches after a second's wait, and the TV shows half-drawn frames.

### 13. Omarchy

The omarchy-arm port at its pin, with a Tegra210 platform and a fix for
Qt 6.12 (`patches/omarchy-arm/`), for the desktop user `config.sh` names
(`OMARCHY_USER`: `omarchy`, unless `config.local.sh` names another).
`scripts/20` asks for a new user's password at the start, then runs by
itself. An existing user keeps its password. `scripts/22` then locks the
default logins, once you confirm the user's password is one you chose:

    scripts/20-install-omarchy.sh --dry-run <the SHIELD's address>   # install.sh's plan only; it still runs on the SHIELD
    scripts/20-install-omarchy.sh <the SHIELD's address>             # 30-60 minutes
    scripts/21-switch-to-networkmanager.sh <the SHIELD's address>    # Wi-Fi, with a way back
    scripts/22-lock-default-logins.sh <the SHIELD's address>         # the default root and alarm logins off
    ssh ... root@<address> systemctl reboot                          # into the login screen

Omarchy runs on NetworkManager. `scripts/20` gives it the Wi-Fi networks
iwd knows, asking for the same address, and `scripts/21` tries the switch
before any reboot: unless SSH comes back through NetworkManager within two
minutes, the SHIELD goes back to iwd. The login screen asks only for the
password: it logs in as that user.

### 14. Memory at 1600 MHz (optional, by hand for now)

The memory clock starts at 800 MHz, where cboot leaves it. The kernel's EMC
driver and the trained table U-Boot passes on take it to stock's 1600 MHz,
where glmark2's scenes ran 50 to 100% faster and SuperTuxKart about 17%:

    tools/emc-rate.sh <the SHIELD's address> 1600000000   # a reboot timer covers a hung switch
    tools/emc-rate.sh <the SHIELD's address> status

The rate holds until the next boot. It passed memtester at each step and a
36-minute soak at 1600 MHz (`docs/benchmarks.md`). It becomes the boot
default after longer soaks and cold boots.

### Next (not scripted yet)

1. Pair a Bluetooth keyboard.
2. Audio.
3. The memory clock at 1600 MHz from boot.
4. The SSD on a USB 3 link (most likely a matter of its cable).
5. Omarchy trimmed down for a media center.

`docs/problems.md` lists every open issue.
