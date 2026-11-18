# Agoralo — HumHub core patches

Every change to HumHub core files (anything outside `protected/modules/agoralo*`,
`themes/Agoralo`, `docs/agoralo`, `deploy/` and `.github/workflows/agoralo-*`) is listed here,
so it can be re-checked on each HumHub upgrade.

| Date | File(s) | Why | Upstream issue/PR | Still needed? |
|---|---|---|---|---|
| — | — | No core patches yet. | — | — |

Repo-level (non-runtime) adjustments to upstream files:

- `CLAUDE.md` — Agoralo header added on top, pointing to `docs/agoralo/AGORALO.md`.
- `.gitignore` — `!themes/Agoralo` so the Agoralo theme is tracked.
- `protected/modules/.gitignore` — `agoralo*` module directories are tracked.
