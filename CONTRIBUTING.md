# Contributing

Thanks for helping. This project runs Omarchy on one board, the NVIDIA SHIELD TV 2017 (`darcy`), on mainline Linux. Code, testing on hardware, documentation and problem reports are all welcome.

## Where to start

- **What isn't done yet:** the gaps in the README's status table: surround sound and the TV remote (HDMI-CEC), measuring video playback, Bluetooth pairing, Ethernet with a link, the SSD on a USB 3 link, and the memory clock at 1600 MHz from boot. Sending the kernel and Mesa fixes upstream is open too.
- **Testing:** run the steps in [docs/install.md](docs/install.md) on your own SHIELD TV 2017 and report anything that differs. Another board is the most useful test there is.

## Reporting a problem

Open an issue with:
- your board, as `fastboot oem dtbname` names it (`scripts/07` records it), and the SHIELD software version
- this repository's commit, and the kernel build on the SHIELD (`uname -v`)
- the step and the script's full output
- the relevant log: `journalctl -b`, `dmesg`, or a photo of U-Boot's log screen

Leave out anything private: `device-info/` (serial numbers, your SSH key), Wi-Fi passwords, MAC addresses.

## Making a change

- **Safety first.** Never flash `dtb`, the bootloader blob, BCT, TOS, EKS or the partition table. Never relock the bootloader with a custom image installed (see "Safety rules" in `docs/install.md`). Before a risky driver or clock change, arm a way back, such as the sysrq reboot timer the tools here use.
- **Reproducible.** Every step is a script under `scripts/` or `tools/`. Versions, commits and checksums are pinned in `config.sh`. A change to Linux, U-Boot, Mesa or omarchy-arm goes in as a patch under `patches/<project>/`, made with `git format-patch`; the build scripts apply them in order.
- **Evidence.** Say what you measured, and on which kernel build. New numbers go in `docs/benchmarks.md` with their conditions, and their raw output in `benchmarks/`.
- **Docs.** Update the page your change touches: `docs/findings.md`, `docs/lessons.md`, `docs/install.md`, or the README's status table. `NOTES.md` is the project's log. Add to it, and when later work corrects an entry, mark the entry *[Later: …]* rather than rewriting it.
- **Commits.** One change per commit. The subject says what changed. The body says why, and what was tested.
- **Shell scripts** source `scripts/lib.sh`, which gives strict mode, logging, the pins and `on_shield`. Quote variables, and check with `bash -n`.

## Pull requests

Describe the change and why it's needed. Say what you tested on hardware (the kernel build, the steps, the result), and what still needs checking. Keep secrets, device data and NVIDIA's files out of the diff.

## License

By contributing, you agree that your work is licensed like the file it changes:
- this project's own files: MIT ([LICENSE](LICENSE))
- `patches/`: the license of the project each patch applies to
- files marked otherwise: GPL-2.0 where their SPDX header says so
