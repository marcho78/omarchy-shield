# Brief: the research index, and the claims later work corrected

This repo (~/projects/nvidia) ports Omarchy to the NVIDIA SHIELD TV 2017 ("darcy"). We're adding short, plain-language docs on top of the existing record. This task is **analysis only**. Change no files in the repo. Write your answer as Markdown to the path in the prompt, and reply with only that path.

Read these:
- `NOTES.md`, the day-by-day log
- `README.md`
- `research/`: 19 briefs (`*-brief.md`) and the agents' answers (`ncodex-*`, `ngrok-*`, `zai-*`, `antigravity-*`)
- `git log` with the commit bodies (89 commits)

## Task A: research index

Write one table row per brief. Some answer files have no brief, for example `ncodex-boot-chain-brainstorm.md` and `*-cboot-boot-failure.md`; give each of those a row too.

| Topic | Question (one line) | Answered by (files) | Used (what, with evidence) | Not used, or wrong (what, with evidence) |

- **Evidence** is a commit hash or `NOTES.md:<line>`. If you find no record that a piece of advice was used or turned down, write "no record".
- **Length:** keep each cell under about 25 words.

## Task B: claims that later work corrected or replaced

Find statements in NOTES.md, README.md or commit messages that later work disproved, and plans that changed. For each one, give:
- the claim, as a short quote, and where it is (`file:line` or commit)
- what replaced it, and where
- "unmarked" if the earlier text doesn't point to the correction

List only items with evidence on both sides. Include plan changes, for example the root filesystem moving from the eMMC to a USB disk.

## Rules
- **Citations:** cite every point. Don't guess; say when something is unknown.
- **Style:** plain words, terse, at most about 250 lines in all.
- **Secrets:** don't copy passwords, Wi-Fi names or serial numbers into your answer.
