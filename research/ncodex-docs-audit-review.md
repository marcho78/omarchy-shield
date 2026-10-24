# A. Wrong or unsupported

1. **Critical — a local account name and a derivable live password are published.** `NOTES.md:2380-2383` says the user's name “stays local” and then names it; `NOTES.md:2393-2400` says that account still has its installation password. Combined with `NOTES.md:1875-1879`, which states how that password was formed, this discloses the password of a wheel/sudo account. The new raw files also repeat the account name (`benchmarks/system/k21-system-benchmark.txt:15`; `benchmarks/supertuxkart/k15-dynamic-lighting.txt:3,11-22`). Change the password immediately, redact the name/password relationship and raw paths, and purge the leaked history if it has been shared. Do not merely edit the latest commit.

2. **High — “only boot and recovery partitions are ever written” is false as a project-wide promise.** `README.md:53` and `docs/problems.md:9` conflict with the documented eMMC option, which overwrites `UDA` (`docs/install.md:213-215`; `config.sh:93-99`). Say that the **default USB-root path** writes only `boot`/`recovery`; the optional eMMC path also overwrites Android userdata.

3. **High — the recovery image is not the source of GPU firmware.** `docs/problems.md:11` says `scripts/04` extracts Wi-Fi, Bluetooth, and GPU firmware. In fact, `VENDOR_FIRMWARE` contains only Broadcom Wi-Fi/BT files (`config.sh:82-91`), and `scripts/04-unpack-recovery.sh:38-46` extracts only that list. The installed GPU firmware is supplied separately as `linux-firmware-nvidia` (`NOTES.md:1274`). Correct the sentence accordingly.

4. **High — the docs overstate password replacement.** `docs/install.md:270`, `docs/findings.md:91`, and `docs/timeline.md:22` say the user chooses/gets their own password. `scripts/20-install-omarchy.sh:46-53,71-76` prompts only when the account does not exist; an existing account keeps its old password. `NOTES.md:2384-2387` records the narrower behavior. Say “a newly created user chooses a password; an existing user's password is unchanged,” and require an explicit reset before `scripts/22` locks recovery accounts.

5. **High — `--dry-run` is not “nothing changes.”** The promise at `docs/install.md:273` is contradicted by `scripts/20-install-omarchy.sh:59-64`, which force-checks out, cleans, and reapplies patches locally, and by `:129-151`, which replaces the remote checkout, creates a temporary sudoers rule, truncates a log, and starts a transient service. Describe it as “runs the upstream installer in its dry-run mode, but stages files and service state,” or make the wrapper truly read-only.

6. **Medium — Bluetooth is not fully demonstrated as “Works.”** `README.md:20` gives that status while admitting pairing is untested. The evidence proves only that the controller is powered/configured (`NOTES.md:1033-1039`); actual pairing remains open (`docs/problems.md:69`). Use “Controller works; pairing untested.”

7. **Medium — “No serial port” is unsupported.** `docs/findings.md:13` and `docs/problems.md:12` turn an access uncertainty into a hardware fact. The contemporaneous source says only “no known serial access” (`NOTES.md:176`), and the research says retail UART-A pad access is **UNKNOWN** (`research/ncodex-boot-chain-brainstorm.md:28`). Use “No known accessible debug UART.”

8. **Medium — reviewer independence is overstated.** `docs/findings.md:18` says all four independently found the HDMI power-domain cause. The log says n-codex and n-grok found it independently, while antigravity and Z.ai agreed (`NOTES.md:579-581`; commit `06ec1f0`). Correct both `docs/findings.md:18` and the summary wording in `research/README.md:21`.

9. **Medium — the research workflow was not uniformly review-before-action.** `research/README.md:3` says every hard problem was reviewed before action and every claim checked before a change. Step 3 was committed at 18:33 in `7907e0f`, while the four reviews were committed at 18:43 in `e9b691f`; the dirty-page review explicitly occurred after kernel #20 was flashed (`NOTES.md:2311-2317`, commits `d4401c6` then `43a9559`). Say reviews informed many decisions, but some audited prepared or already-tested changes afterward.

10. **Medium — the thermal sequence is reversed.** `research/README.md:27` says fan then throttle and cites the commits in the opposite order. Commit timestamps show throttle `4d82b89` (23:21), fan `d4cd616` (23:40), idle `7a322c8` (00:08), DFLL `5fc27a7` (00:27). Correct the order to throttle → fan → idle → DFLL.

11. **Medium — the 3 FPS diagnosis/fix is false as written.** `docs/problems.md:42` attributes “SuperTuxKart at 3 FPS” to cache cleaning and says two rounds of `0006` fixed it. The first cache change reduced CPU cleaning, yet dynamic lighting stayed at 3.2 FPS because the GPU became the limit (`docs/benchmarks.md:51-53`; `NOTES.md:2062-2068`). The later cache rewrite explains 20.7 → 37.2 FPS only with dynamic lighting disabled (`docs/benchmarks.md:54-60`). Split those two findings.

12. **Medium — the 50–100% EMC claim is generalized too far.** `docs/install.md:287-290` says 1600 MHz “makes the GPU 50 to 100% faster.” That range belongs to selected glmark2 scenes (`docs/benchmarks.md:40-45`); SuperTuxKart improved only 17.7 → 20.7 FPS from EMC alone (`:54-56`, about 17%). Say “selected glmark2 scenes gained 50–100%; this STK run gained about 17%.”

13. **Medium — not every benchmark number has saved raw output.** `docs/benchmarks.md:3` and `README.md:39` make an absolute claim. The index itself records no file for the 3.2 FPS run (`benchmarks/README.md:16-18`), Android results are reported rather than raw runs (`docs/benchmarks.md:17-18`; `benchmarks/README.md:64`), and 22.4 s appears only in `docs/benchmarks.md:24` with no matching raw/source entry. Narrow the claim and either add provenance for 22.4 s or remove it. The other headline values checked do agree with the raw files, including 20.937 s, power, 7-Zip, bandwidth, storage, Wi-Fi, glmark2, and STK (`benchmarks/system/k21-system-benchmark.txt:3-24`; `benchmarks/system/k21-reruns.txt:1-15`; `benchmarks/README.md:14-45`).

14. **Medium — the LineageOS credit repeats a corrected claim.** `README.md:90-91` credits Lineage maintainers for “the U-Boot chainload approach,” but Lineage darcy does not use that chain (`NOTES.md:123-129`; `docs/problems.md:50`). Credit Lineage for mirrored NVIDIA sources/packaging references; credit archeYR's foster port as the proven SHIELD chainload precedent.

15. **Low — lack of Vulkan does not by itself imply no GPU compute.** `docs/problems.md:20` says “no Vulkan, so no GPU compute.” The actual limitation is that NVK does not support Tegra **and** no OpenCL driver is configured (`docs/benchmarks.md:71-74`). State both.

16. **Credential/privacy scan.** Distribution-default password pairs are printed in new documentation and comments (`docs/install.md:180-183,276`; `docs/findings.md:92`; `scripts/22-lock-default-logins.sh:2-3`). They are public defaults, not private secrets, but they are credentials and should be labeled as such rather than repeated unnecessarily. A private LAN address is also present in `benchmarks/cpu/soak-2014mhz.txt:12`. No Wi-Fi name, device serial, real MAC address, or Geekbench claim key was found in the newly added docs/raw outputs; the claim key is explicitly removed (`benchmarks/README.md:3-6`; `benchmarks/geekbench/k21-cli.txt:68-70`).

# B. Missing

1. **DFLL limitations matter to anyone reproducing the CPU result.** The docs omit that low requested rates measure high, mainline lacks one-shot floor calibration, the live PWM index is unproved, monitor reads may be torn, cold-floor handling is absent, and timing safety is plausible rather than proved (`NOTES.md:1526-1563`). Add this under CPU constraints, not just the successful 2.0145 GHz result.

2. **The HDMI status omits open signal and power-domain work.** Colour range, drive current, and 4K/HDMI 2.0 scrambling remain untested (`NOTES.md:1212-1216`). More importantly, the current DT still deletes `pd_sor` and all SOR-domain links (`kernel/dts/darcy.dts:111-155`), despite the earlier plan to restore the domain once tegra-drm owned HDMI (`NOTES.md:620`). Document that as a power-management workaround/open issue.

3. **The first Linux handoff's safety-critical fixes are absent from the findings page.** The framebuffer had to be `reserved-memory/no-map`, unused rails had to remain on, and three always-on rails needed `regulator-boot-on` to avoid an off pulse (`NOTES.md:380-405`; `research/README.md:19`). These explain why the initial console survived and belong in `docs/findings.md`.

4. **CPU idle's measured result is incomplete.** The docs say C7 works, but omit that 1–4% of secure-monitor entries were rejected and that power/temperature were unchanged within noise because WFI already clock-gated the cores (`NOTES.md:1485-1494`). This is an important negative result.

# C. Unclear

1. **Install-guide move: pass.** Comparing `docs/install.md` with `git show e5b03f8^:README.md` finds no accidental step drift. Besides the expected removal of the old front matter/layout/credits, the only substantive additions are the `scripts/16` update paragraph (`docs/install.md:239-242`), manual EMC step (`:285-296`), and revised Next list (`:298-306`), matching commit `e5b03f8`.

2. **“Recovery restores it completely” can be read as restoring erased user data.** `docs/install.md:29-30` and `docs/problems.md:10` should say the recovery image reinstalls the stock OS/partitions; it cannot recover apps, accounts, or settings erased by unlocking.

3. **The GPU patch sentence sounds exhaustive.** `docs/install.md:261-263` says the kernel needs `0004` and `0005 “for the GPU,” but first access also requires the fuse-clock fix `0001` (`docs/findings.md:61-64`). Say those two patches fix the later stall/page-flip bugs.

4. **The displayed boot-time components appear not to add up only because each is rounded.** `docs/benchmarks.md:24` shows 10.8 + 10.2 beside 20.9; the raw values are 10.752 + 10.184 = 20.937 (`benchmarks/system/k21-system-benchmark.txt:6`). Use one decimal only for the total, or show 10.75 + 10.18.

5. **“Every script is safe to re-run” is too broad.** `docs/install.md:40-41` needs exceptions/semantics: destructive steps are explicitly called out, and `scripts/20` currently has partial-failure and dry-run side effects described below.

# D. Scripts

1. **Critical — `scripts/22` can bless the already-disclosed weak desktop password.** Its only password test is `passwd -S ... == P` (`scripts/22-lock-default-logins.sh:21-25`), which proves merely that some password hash exists. `scripts/20` leaves existing users unchanged (`scripts/20-install-omarchy.sh:46-53,71-76`). Require an explicit password reset/confirmation for an existing account before locking the two recovery logins; do not infer safety from status `P`.

2. **High — partial user creation is not recoverable on rerun.** `useradd && chpasswd` is one SSH pipeline (`scripts/20-install-omarchy.sh:71-74`). If the connection/process fails after `useradd` but before `chpasswd`, the account remains, and the next run sees it as existing and skips both the prompt and password setup (`:46-53,75-76`). Create the account and set/verify its password in a rollback-capable remote script, or explicitly detect a locked/no-password account on every run.

3. **High — `OMARCHY_USER` is interpolated into root shell commands without validation or quoting.** It reaches `id`, `useradd`, paths, `rm -rf`, `chown`, sudoers text, systemd arguments, and SDDM state (`scripts/20-install-omarchy.sh:43-46,70-76,129-151,171-174`; `scripts/22-lock-default-logins.sh:19-25,43`). A typo containing shell syntax can execute or delete unintended targets. Enforce a strict local-account-name regex and pass a shell-escaped value (or positional parameter) to remote scripts.

4. **High — `--dry-run` mutates both host and SHIELD.** The exact writes are at `scripts/20-install-omarchy.sh:59-64,129-151`; only the nested installer gets `--dry-run` (`:134-151`). Move checkout preparation into a temporary worktree and make the remote phase inspection-only, or rename the mode and document its staging writes.

5. **High — the root-unlock timer has a race and failure path.** After proving a new SSH login, failure to stop the timer is only a warning and execution continues (`scripts/22-lock-default-logins.sh:30-40`). The timer can therefore unlock root after the script claims success; stopping only the timer also does not rule out an already-started service. Stop both timer and service, re-lock root, and fail unless a final `passwd -S root` check reports locked before locking the other account.

6. **Medium — `config.local.sh` is executable, unrestricted configuration.** `scripts/lib.sh:4-10` sources it into every script after `config.sh`, so it can execute commands and override `ROOT`, source/checksum pins, product guards, partition choices, or any other variable. `README.md:60` describes it merely as optional personal settings. Prefer a declarative/allowlisted parser (currently only `OMARCHY_USER` is advertised), or explicitly document it as fully trusted shell and revalidate safety-critical variables after loading it.

7. **Positive check:** the newly entered password itself is read hidden and sent through SSH standard input to `chpasswd`, not placed in an argument or log (`scripts/20-install-omarchy.sh:47-53,71-74`; `NOTES.md:2384-2387`). The defect is lifecycle/verification for existing and partially created accounts, not this transport choice.
