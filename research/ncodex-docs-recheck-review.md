# Point by point

## A. Wrong or unsupported

| Point | Status | Evidence |
|---|---|---|
| A1 account/password disclosure | **partly** | The password-forming relationship and the current-password statement are gone from the tip (`NOTES.md:1876-1880,2378-2406`), but they remain in history (`a2db954^:NOTES.md:1876-1878,2399-2400`). The account name remains in raw files by deliberate choice (`research/README.md:39`). Whether the exposed password was changed is **UNKNOWN** from the repo; confirmation in `scripts/22` is not rotation. Purge history if published and rotate the password. |
| A2 partitions written | **done** | The default USB path and optional userdata write are now distinguished (`README.md:53`; `docs/problems.md:9`; `docs/install.md:29-35,216-218`). |
| A3 GPU-firmware source | **done** | Recovery firmware is limited to Wi-Fi/BT and USB/GPU firmware is separated (`docs/problems.md:11`; `config.sh:57-73,82-91`; `NOTES.md:1274`). |
| A4 password wording | **done** | New versus existing users are distinguished, and locking requires confirmation (`docs/findings.md:90-93`; `docs/install.md:273-280`; `scripts/22-lock-default-logins.sh:22-29`). A passwordless-existing-user wording regression is listed below. |
| A5 dry-run promise | **done by documentation** | The deliberate side effects are now stated (`docs/install.md:277`; `scripts/20-install-omarchy.sh:19-21,133-155`). It is still not read-only, by the user's stated choice. |
| A6 Bluetooth status | **done** | Status is “Controller works,” with pairing still untested (`README.md:20`; `docs/problems.md:70`). |
| A7 serial wording | **done** | Both pages now say no way is known to reach a serial port (`docs/findings.md:13`; `docs/problems.md:12`). |
| A8 reviewer independence | **done** | The two independent finders and two confirming reviewers are accurately separated (`docs/findings.md:19`; `research/README.md:21`; `NOTES.md:579-581`). |
| A9 review-before-action claim | **partly** | `research/README.md:3` is corrected, but `docs/problems.md:22` still says every claim is checked “before acting,” contradicted by the post-test review recorded at `NOTES.md:2311-2317`. |
| A10 thermal order | **done at the cited location** | `research/README.md:27` now gives throttle → fan → idle → DFLL with the first two commits ordered correctly. `docs/problems.md:36` still says “Fan, 0002,” so that separate summary should be aligned. |
| A11 3 FPS diagnosis | **done** | Dynamic-lighting GPU limitation and later no-dynamic cache gain are separate rows (`docs/problems.md:42-43`; `docs/benchmarks.md:51-60`). |
| A12 EMC speed claim | **done** | glmark2's 50–100% and STK's ~17% are now scoped separately (`docs/install.md:289-300`; `docs/benchmarks.md:40-56`). |
| A13 raw-output absolutism | **partly** | `docs/benchmarks.md:3` names the hand-read and reported exceptions, and 22.4 s now has raw evidence (`benchmarks/system/k21-boot-later.txt:1-5`; `benchmarks/README.md:42-46`). But `README.md:78` still says `benchmarks/` has raw output for “every benchmark run,” despite the no-file run (`benchmarks/README.md:16-18`). |
| A14 Lineage credit | **done** | archeYR gets the proven-chain credit; Lineage gets source/wrapping-model credit (`README.md:87-91`; `NOTES.md:123-129`). |
| A15 GPU-compute reasoning | **done** | Missing Tegra Vulkan support and missing OpenCL are now both stated (`docs/problems.md:20`; `docs/benchmarks.md:71-74`). |
| A16 credentials/privacy scan | **partly, deliberately** | Default credential values were removed from current docs/comments (`docs/install.md:183-186`; `scripts/22-lock-default-logins.sh:1-5`). The raw account name and private LAN address remain by explicit choice (`research/README.md:39`; `benchmarks/cpu/soak-2014mhz.txt:12`). No claim key was reintroduced (`benchmarks/geekbench/k21-cli.txt:68-70`). |

## B. Missing

| Point | Status | Evidence |
|---|---|---|
| B1 DFLL limitations | **done** | The calibration, monitor, cold-floor, and timing caveats are summarized in `docs/problems.md:75`, consistent with `NOTES.md:1526-1563`. |
| B2 HDMI open work / `pd_sor` | **done** | Signal questions and the deleted power domain are listed (`docs/problems.md:72-75`; `kernel/dts/darcy.dts:111-155`). |
| B3 first-handoff safeguards | **done** | no-map framebuffer, boot-on rails, and preserved early supplies are in `docs/findings.md:18`, backed by `NOTES.md:380-405`. |
| B4 cpuidle negative result | **done** | Rejected entries and unchanged power/heat are recorded (`docs/findings.md:54-58`; `NOTES.md:1485-1494`). |

## C. Unclear

| Point | Status | Evidence |
|---|---|---|
| C1 install move | **done / no change required** | The original `e5b03f8` move remains the reviewed baseline; later edits are explicit audit corrections (`a2db954`). |
| C2 recovery wording | **done** | It now says stock Android is reinstalled but erased user data is not recovered (`docs/install.md:29-31`; `docs/problems.md:10`). |
| C3 GPU patches | **done** | Fuse-clock `0001` is separated from the `0004`/`0005` stall/display fixes (`docs/install.md:260-266`; `docs/findings.md:62-65`). |
| C4 boot-time rounding | **done** | 10.75 + 10.18 = 20.94 is shown and sourced (`docs/benchmarks.md:24`; `benchmarks/system/k21-system-benchmark.txt:6`). |
| C5 rerun wording | **done** | The blanket safety claim became a qualified rerun/confirmation statement (`docs/install.md:40-44`). |

## D. Scripts

| Point | Status | Evidence |
|---|---|---|
| D1 weak existing password | **done as a gate, not as rotation** | `scripts/22` requires an explicit confirmation before locking (`scripts/22-lock-default-logins.sh:22-29`). The actually exposed password still must be rotated; repo status is **UNKNOWN** (A1). |
| D2 partial account creation | **done** | `scripts/20` now prompts whenever status is not `P`, reuses an existing account, then runs `chpasswd` (`scripts/20-install-omarchy.sh:46-57,73-80`). |
| D3 username shell injection | **done for syntax** | The allowlist prevents shell metacharacters (`scripts/lib.sh:17-20`). Reserved/system-account semantics remain unsafe; see below. |
| D4 dry-run mutation | **done by documentation** | Side effects are stated rather than removed (`scripts/20-install-omarchy.sh:19-21`; `docs/install.md:277`). |
| D5 unlock-timer race | **partly** | Both units are named and lock state is checked (`scripts/22-lock-default-logins.sh:42-45`), but stop failure is discarded and root is not re-locked; details below. |
| D6 unrestricted local config | **done by documentation** | It is explicitly trusted shell (`scripts/lib.sh:7-10`; `README.md:60`), and its command-bound username is validated (`scripts/lib.sh:17-20`). |
| D7 password transport | **done / unchanged** | The secret remains hidden input sent only on SSH stdin (`scripts/20-install-omarchy.sh:51-57,74-78`). |

# New errors

- **Medium:** The new summary claims all audit points except the three deliberate omissions were handled (`research/README.md:39`), but A9, A13, and D5 remain partial, and A1's history/rotation status remains unresolved. Replace “all” with a precise statement.
- **Low:** Documentation now says every existing user keeps its password (`docs/install.md:273-275`; `docs/findings.md:92`), while the new recovery logic resets an existing account whose status is not `P` (`scripts/20-install-omarchy.sh:46-80`). Say “an existing user with a usable password keeps it.”

# The scripts

- **High:** `scripts/22-lock-default-logins.sh:43-45` runs `systemctl stop ...` and then `passwd -S` on a new line. The remote shell returns the pipeline's status, so a failed stop is ignored; root may read locked while the unlock timer remains armed. Chain with `&&`, stop both units, explicitly `passwd -l root`, then verify `L`; fail on any step.
- **High:** The regex accepts protected/system accounts. A valid-looking `OMARCHY_USER` can name the administrator, distribution-default, or another service account; `scripts/20` may then set that account's password and install into `/home/$user` (`scripts/lib.sh:17-20`; `scripts/20-install-omarchy.sh:49,75-77,133-155`). Reject reserved names and, for an existing user, verify expected UID range, home, shell, and wheel intent before changing it.
- **Medium:** The status probe conflates a missing/passwordless account with SSH or remote-command failure: its failing command is inside a substitution whose result is compared as a string (`scripts/20-install-omarchy.sh:49`). A transient probe failure can cause an unnecessary secret prompt and, if connectivity returns, reset an existing user's password (`:74-77`). Return an explicit `MISSING`/status sentinel and abort on transport or unexpected output.
