# Brief: an accuracy audit of the new docs

This repo (~/projects/nvidia) ports Omarchy to the NVIDIA SHIELD TV 2017 ("darcy"). The commits e9af3d4..e5b03f8, on top of the 89-commit bring-up, add:
- the raw benchmark outputs (`benchmarks/`)
- a login change (`scripts/20` asks for the password, the new `scripts/22`, `config.local.sh`)
- new docs: `README.md`, `docs/install.md`, `docs/findings.md`, `docs/problems.md`, `docs/benchmarks.md`, `docs/timeline.md`, `research/README.md` and `benchmarks/README.md`
- *[Later: …]* markers and a B9 section in `NOTES.md`

The user wants these docs to be accurate and truthful, to cover every finding, difficulty, constraint and number, and to read plainly.

This task is **analysis only**. Change no files in the repo. Write your answer as Markdown to the path in the prompt, and reply with only that path.

## What to check

Check every claim and every number in the new docs against the sources:
- the commit messages and diffs (`git log`, `git show`)
- `NOTES.md` and `research/`
- the raw outputs in `benchmarks/`
- the code: `patches/`, `scripts/`, `tools/`, `kernel/`

Also check that `docs/install.md` is a faithful move of the old README's steps (`git show e5b03f8^:README.md`), apart from its three stated additions. Check the additions themselves too.

Then review the changed scripts for bugs: `scripts/20-install-omarchy.sh`, where the password prompt and the stdin to `chpasswd` are new; `scripts/22-lock-default-logins.sh`; and `scripts/lib.sh`, which now reads `config.local.sh`.

## The answer, in four sections

- **A. Wrong or unsupported.** These must be fixed. Give `file:line`, the claim, what the source says (with its citation) and a correction.
- **B. Missing.** A finding, difficulty, constraint, open issue or number in the sources that the new docs leave out, if it matters to a reader.
- **C. Unclear.** Wording a newcomer would misread. Be brief.
- **D. Scripts.** Bugs or risks in the changed scripts.

## Rules
- **Citations:** cite every point. Don't guess; say when something is unknown.
- **Secrets:** flag any password, Wi-Fi name, serial number, MAC address or Geekbench claim key in the new files, but don't copy its value into your answer.
- **Length:** terse, at most about 200 lines in all.
