# Research: briefs and reviews

Hard problems went to other AI agents for review. A self-contained brief (`*-brief.md`) went to each agent, and each answered in its own file. Their claims were checked against the source before we used them, and NOTES.md records the ones that turned out wrong. Most reviews came before the change they shaped. Some checked a change already prepared or tested.

| Agent | Tool | Reviews |
|---|---|---|
| n-codex | Codex | 25 |
| n-grok | Grok | 8 |
| antigravity | Gemini | 7 |
| Z.ai | GLM, through opencode | 4 |

n-grok and Z.ai stopped answering at their usage limits, and antigravity at its quota, so n-codex reviewed the later work alone. n-codex built this index (`ncodex-docs-research-review.md`, from `docs-research-brief.md`) and gives the evidence for each row line by line.

| Topic | The question | Answered by | Used | Wrong, or not used |
|---|---|---|---|---|
| Boot chain (no brief) | Which path from cboot, and how to debug blind | n-codex | U-Boot in the recovery slot, a FIT payload, careful flashing (a524e39) | "LineageOS boots darcy this way" was wrong |
| cboot boot failure (no brief) | Why raw U-Boot failed | n-codex, n-grok | gzip U-Boot, the recovery-slot loop (686b74f) | The probe's size wasn't the problem: 24 MiB arrived intact |
| U-Boot patch (no brief) | Hazards in our board code | n-codex | Seven of nine findings fixed (1db0e92) | The predicted relocation overlap never happened |
| `linux-handoff` | Keep cboot's picture through the first Linux boot | n-codex, n-grok | no-map framebuffer and ramoops, boot-on rails (371a6dc) | Turning off the pinmux, PMIC and IOMMU was turned down after checking |
| `hdmi-black` | Was the PMIC blanking HDMI? | n-codex, n-grok, Z.ai | Stock PMIC values (e91a6a4) | The PMIC wasn't the cause |
| `hdmi-link` | Which Linux probe drops the HDMI link? | all four | n-codex and n-grok found the power-partition teardown independently, and antigravity and Z.ai agreed (06ec1f0) | No record of anything else |
| `firstboot` | The installed system's first boots | all four | Keep tegra-drm out, matching modules, iwd's crypto (7847688) | Z.ai's module name and antigravity's quoted code were wrong |
| `step3` | Wi-Fi: kernel options, country, module update | all four | Crypto options, the country map, two script bugs (7907e0f, 2778bdf) | Much of antigravity's ordering section describes code we don't have |
| `hdmi-drm` | tegra-drm's first HDMI bring-up | n-codex, n-grok, antigravity | The device-tree recipe, always-on HDMI 5 V (7cf0d01) | Two review claims were corrected in NOTES |
| `gpu-review` | A safe first nouveau load | n-codex, n-grok, antigravity | The rail, pinmux and rollback plan (708b4f6) | The expected firmware issues never came; a missing fuse clock did |
| `gpu-hang` | Why the first register read hangs | n-codex | The fuse clock (b09a55d) | Reset and memory-flush changes weren't needed |
| `thermal` | Why it shut down, and how to cool it | n-codex, antigravity | Throttle, fan, idle, DFLL, in that order (4d82b89, d4cd616) | A guessed thermal-trip write wasn't used |
| `plan2` | Order of CPU, GPU and desktop work | n-codex, antigravity | The staged plan (bdccfb0) | antigravity's speedo, GPU-trip, package and "kmsro stub" claims were wrong |
| `dfll-followup` | Reading the DFLL's monitor | n-codex | Cautious reading, staged clock steps (a92151d) | Timing safety is plausible, not proved |
| `mesa-tegra` | Is upstream's Mesa fix enough? | n-codex | Six more fixes in `mesa-darcy` (2d4908d) | The upstream fix alone wasn't enough |
| `gpu-clock` | One-second stalls and a crash | n-codex | Mesa follow-ups (2d4908d) | The stalls came from stale progress reads (326afce), not the clock |
| `nouveau-sync` | Clean only buffers the CPU may have written | n-codex | The first `0006`, then two fixes (f6abea2, 4c8e65b) | Whole-buffer cleaning still cost 41%, replaced by page tracking |
| `gpu-slow` | Why the GPU is slow | n-codex | Float-target test, no-compression finding, the memory-clock work (e15f585) | Float targets weren't the cost; big pages are untried |
| `emc` | cboot's tables, the driver's hazards, a safe test ladder | n-codex | The conversion, the test ladder, the refresh fix (4c8e65b) | Our first refresh fix ran backwards, found by testing (d005f18) |
| `nouveau-dirty` | The page-tracking rewrite | n-codex | All five fixes (43a9559) | none |
| `omarchy` | The Tegra platform and the network switch | n-codex | Rollback switch, detection, PSI and zram, visudo (f53a3c9) | none; the firewall failure was outside its checklist |
| `omarchy-color` | The colour fix, and restarting while locked | n-codex | `Commons.Color` (54988ed) | Restart while locked: only a workaround, unlock first |
| `docs-research` | This index, and the claims to correct | n-codex | This table, the corrections in `docs/problems.md` | none |
| `docs-audit` | Is every claim and number in the new docs right? | n-codex | Its points, checked first (a2db954, 255cf26) | Left as they are: the raw files keep the user name, as the user chose. `--dry-run` is documented, not made read-only. A private LAN address stays in one raw log. Git history keeps the NOTES lines since removed; the user chose no rewrite. Changing the desktop password is the user's call. |
| `docs-recheck` | Were the audit's fixes right? | n-codex | Three wordings, this row, and the scripts' account and unlock checks | none |
