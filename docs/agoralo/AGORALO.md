# Agoralo — Developer Guide

Agoralo is a modular community platform built on **HumHub** (Yii2, PHP 8.2+).
This repository is a fork of `humhub/humhub` (currently based on **1.18.3**).
Everything Agoralo-specific is layered on top of HumHub so upstream updates stay easy.

## Environments

| | |
|---|---|
| Production | https://agoralo.com (Hetzner, Debian 12, IP `2.28.57.50`) |
| Stack | Nginx · PHP-FPM · MariaDB · Composer · Let's Encrypt — no Docker |
| Web root | `/var/www/agoralo` (git working copy of branch `main`) |
| Server user | `deploy` (code owner); `www-data` runs PHP |
| DB | `agoralo` / user `agoralo_user` — credentials live only on the server |
| Cron | `/etc/cron.d/agoralo-humhub` → `yii cron/run`, `yii queue/run` every minute |

## Branches

| Branch | Role |
|---|---|
| `main` | **Production.** Every push auto-deploys to agoralo.com. Never force-push. |
| `agoralo/<topic>` | Work branches for anything bigger than a small change; merge into `main` when ready. |
| `master`, `develop`, `next`, … | Upstream HumHub branches. Do not develop on them. `master` is only used to bring in HumHub releases. |

## Where changes go (in order of preference)

1. **Admin UI / database settings** — site name, logo, colors, menus, enabled modules. No code needed.
2. **Agoralo modules** — `protected/modules/agoralo-<name>/` (module id `agoralo-<name>`).
   Only directories matching `agoralo*` are tracked by git there; marketplace modules installed
   on the server stay untracked on purpose.
3. **Agoralo theme** — `themes/Agoralo/` (child theme of `HumHub`; SCSS variables + view overrides).
4. **Docs** — `docs/agoralo/`.
5. **HumHub core** (`protected/humhub/`, `static/`, root files) — only when there is no hook,
   event or override that can do it. Every core patch must be listed in
   `docs/agoralo/CORE-PATCHES.md` (file, reason, upstream issue/PR if any), because it must be
   re-checked on every HumHub upgrade.

Module conventions follow HumHub: `module.json`, `Module.php`, `config.php` (event wiring),
`Events.php` (handlers), `resources/`, `views/`, `messages/` (translations; Greek `el`).
See the upstream guide below in `CLAUDE.md` for the event system and migration rules.

## Never in git

- Secrets of any kind (DB passwords, API keys, SMTP, tokens). Server config lives in
  `protected/config/common.php` / `web.php` / `console.php` **on the server only**
  (marked `skip-worktree` there, so pulls never overwrite them).
- `.env`, `protected/runtime/`, `uploads/`, `assets/`, `protected/vendor/` (already ignored).

## Deploy pipeline

```
push to main ──► GitHub Actions "Agoralo deploy"
                   ├─ php -l on changed PHP files
                   ├─ SSH (dedicated key, forced command) ──► ~/agoralo-ci/remote-deploy.sh on server
                   │     ├─ refuse if tracked files were edited on the server
                   │     ├─ git fetch + fast-forward main (never reset/force)
                   │     ├─ composer install --no-dev   (only if composer.lock changed)
                   │     ├─ yii migrate/up --includeModuleMigrations=1
                   │     ├─ yii cache/flush-all
                   │     └─ local HTTPS check
                   └─ public check https://agoralo.com → 200
```

- Workflow: `.github/workflows/agoralo-deploy.yml`; server script: `deploy/remote-deploy.sh`.
- One-time server preparation: `deploy/server-setup-ci.sh` (ownership, sudoers rule, CI key).
  If `deploy/remote-deploy.sh` changes, re-run `install -m 0755 /var/www/agoralo/deploy/remote-deploy.sh ~/agoralo-ci/`
  on the server (the CI key is bound to the installed copy, not the repo copy).
- Server logs: `~/agoralo-ci/logs/` on the server; Actions logs on GitHub.
- Manual deploy on the server: `~/agoralo-ci/remote-deploy.sh`.

### Rollback

`git revert <sha>` on `main` and push — the revert deploys like any change.
Database migrations are **not** reverted automatically; write a new migration if needed.

## Updating HumHub (upstream)

```bash
git remote add upstream https://github.com/humhub/humhub.git   # once
git fetch upstream --tags
git checkout -b agoralo/humhub-<version> main
git merge v<version>            # resolve conflicts; re-check docs/agoralo/CORE-PATCHES.md
# test, then merge into main
```

## Upstream GitHub workflows

The fork inherits HumHub's own workflows (`php-test`, `php-cs-fixer`, `claude-review`, `stale`,
`support`, `notify-docker-release`). They target `master/develop/next` and are not needed for
Agoralo. Disable them in GitHub → Actions → (workflow) → ⋯ → *Disable workflow*, instead of
deleting the files, so upstream merges stay clean. Keep **Agoralo deploy** enabled.

## Working rules (for humans and Claude)

- Small, reviewable commits with clear messages; one topic per commit.
- Check before push: `php -l` on changed PHP files; for modules, keep `module.json` valid JSON.
- After every deploy, verify the affected page on https://agoralo.com.
- Never modify SSH config/keys or firewall rules as part of app work; explain first.
- If something fails, stop and explain before attempting a risky fix.
