#!/usr/bin/env bash
#
# Agoralo — production deploy step (runs ON the server as user `deploy`).
#
# Installed by deploy/server-setup-ci.sh to /home/deploy/agoralo-ci/remote-deploy.sh
# and bound to the GitHub Actions SSH key as a *forced command*: that key can run
# nothing except this script. GitHub sends the commit SHA as the SSH command, which
# arrives here in $SSH_ORIGINAL_COMMAND.
#
# Can also be run by hand:   ~/agoralo-ci/remote-deploy.sh
#
# Steps: fast-forward pull of `main` -> composer install (only if lock changed)
#        -> DB migrations (core + modules) -> cache flush -> local smoke test.
# Stops on the first error. Never resets, stashes or deletes anything.

set -Eeuo pipefail

APP=/var/www/agoralo
BRANCH=main
PHP=/usr/bin/php                       # must match the sudoers rule
YII="$APP/protected/yii"
LOG_DIR="$HOME/agoralo-ci/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
trap 'log "FAILED (line $LINENO): $BASH_COMMAND — nothing was rolled back automatically. Log: $LOG"; exit 1' ERR

# Optional expected commit from GitHub Actions (validated, never executed).
WANT_SHA="${SSH_ORIGINAL_COMMAND:-${1:-}}"
if [[ -n "$WANT_SHA" && ! "$WANT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  log "Rejected argument (not a commit SHA): '$WANT_SHA'"; exit 2
fi

yii() { sudo -n -u www-data "$PHP" "$YII" "$@"; }

cd "$APP"
log "Deploy start on $(hostname) — branch $BRANCH ${WANT_SHA:+expecting ${WANT_SHA:0:10}}"

# ---- preflight ------------------------------------------------------------
[[ -w "$APP/.git" ]] || { log "User $(id -un) cannot write $APP/.git — run deploy/server-setup-ci.sh"; exit 1; }
yii help >/dev/null 2>&1 || { log "Passwordless 'sudo -u www-data php yii' not configured — run deploy/server-setup-ci.sh"; exit 1; }
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "Tracked files were modified directly on the server. Aborting so nothing is lost:"
  git status --short
  exit 1
fi

# ---- code -----------------------------------------------------------------
PREV=$(git rev-parse HEAD)
git fetch --quiet origin "$BRANCH"
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
  log "Switching working copy to branch $BRANCH"
  git checkout --quiet "$BRANCH" 2>/dev/null || git checkout --quiet -b "$BRANCH" "origin/$BRANCH"
fi
git merge --ff-only --quiet "origin/$BRANCH"
NEW=$(git rev-parse HEAD)
log "Code: ${PREV:0:10} -> ${NEW:0:10}  ($(git log -1 --format=%s))"

if [[ -n "$WANT_SHA" ]] && ! git merge-base --is-ancestor "$WANT_SHA" HEAD; then
  log "Expected commit ${WANT_SHA:0:10} is not contained in HEAD — aborting."; exit 1
fi

# ---- dependencies -----------------------------------------------------------
if [[ ! -f protected/vendor/autoload.php ]] || ! git diff --quiet "$PREV" "$NEW" -- composer.json composer.lock; then
  log "composer install (lock changed or vendor missing)"
  composer install --no-dev --optimize-autoloader --no-interaction --no-progress
else
  log "composer: no dependency changes"
fi

# ---- database + caches -------------------------------------------------------
log "Running migrations (core + modules)"
yii migrate/up --includeModuleMigrations=1 --interactive=0

log "Flushing caches"
yii cache/flush-all --interactive=0

# ---- smoke test -------------------------------------------------------------
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve agoralo.com:443:127.0.0.1 https://agoralo.com/ || true)
log "Local HTTPS check: $code"
[[ "$code" == "200" || "$code" == "302" ]] || { log "Unexpected HTTP status $code — check /var/log/nginx/error.log"; exit 1; }

log "Deploy OK — now at ${NEW:0:10}"
