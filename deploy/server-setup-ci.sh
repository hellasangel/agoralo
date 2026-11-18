#!/usr/bin/env bash
#
# Agoralo — ONE-TIME server preparation for GitHub Actions auto-deploy.
# Run on the server as user `deploy` (uses sudo only where needed):
#
#   curl -fsSL https://raw.githubusercontent.com/hellasangel/agoralo/main/deploy/server-setup-ci.sh -o ~/server-setup-ci.sh
#   less ~/server-setup-ci.sh          # review first
#   bash ~/server-setup-ci.sh
#
# What it does (each step is explained and logged; it stops on any error):
#   1. Checks /var/www/agoralo is a git clone; shows owner, branch, local changes.
#   2. [asks first] Sets ownership so `deploy` owns the code and `www-data` owns
#      only the runtime-writable dirs (assets, runtime, config, modules, uploads).
#   3. Marks server-local config files (protected/config/{common,web,console}.php)
#      as skip-worktree, so local settings never block a pull and are never lost.
#   4. Points origin at GitHub, switches the working copy to `main` (fast-forward only).
#   5. Installs ~/agoralo-ci/remote-deploy.sh (the only thing the CI key may run).
#   6. Adds ONE narrow sudoers rule: deploy may run `php protected/yii ...` as www-data.
#   7. Generates a dedicated CI SSH key and APPENDS it to ~/.ssh/authorized_keys with
#      `restrict,command=...` — existing keys are never touched or removed.
#   8. Prints the 5 GitHub secrets to paste, then destroys the private key on disk.
#   9. Read-only firewall check (does NOT change any rule) + a test deploy run.
#
# It never edits sshd_config, never disables SSH, never deletes keys, never changes firewall rules.

set -Eeuo pipefail

APP=/var/www/agoralo
BRANCH=main
REPO_URL=https://github.com/hellasangel/agoralo.git
PUBLIC_IP=2.28.57.50
CI_DIR="$HOME/agoralo-ci"
KEY_COMMENT=agoralo-github-actions
SUDOERS=/etc/sudoers.d/agoralo-deploy
WRITABLE=(assets protected/runtime protected/config protected/modules uploads)
LOCAL_CONFIG=(protected/config/common.php protected/config/web.php protected/config/console.php)
LOG="$HOME/agoralo-setup-ci-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    !!  %s\033[0m\n' "$*"; }
trap 'printf "\033[1;31mSTOPPED at line %s: %s\nNothing risky was attempted. Log: %s\033[0m\n" "$LINENO" "$BASH_COMMAND" "$LOG"; exit 1' ERR
confirm() { read -r -p "    $1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

[[ "$(id -un)" == "deploy" ]] || { echo "Run as user 'deploy'."; exit 1; }

# ---------------------------------------------------------------------------
step "1. Inspect $APP"
[[ -d "$APP/.git" ]] || { warn "$APP is not a git clone. Stop here and tell Claude how the site was installed."; exit 1; }
stat -c '    owner of %n: %U:%G' "$APP" "$APP/.git" "$APP/index.php"
sudo git -c safe.directory="$APP" -C "$APP" rev-parse --abbrev-ref HEAD | sed 's/^/    branch: /'
sudo git -c safe.directory="$APP" -C "$APP" remote get-url origin | sed 's/^/    origin: /' || true
echo "    local changes to tracked files:"
sudo git -c safe.directory="$APP" -C "$APP" -c core.fileMode=false status --short --untracked-files=no | sed 's/^/      /'

# ---------------------------------------------------------------------------
step "2. Ownership model"
cat <<EOF
    Planned:
      - $APP (code, .git, vendor)        -> deploy:www-data, dirs setgid, group read-only
      - ${WRITABLE[*]}
                                         -> www-data:www-data, group-writable (deploy is in group www-data)
      - add user deploy to group www-data
    nginx/php-fpm keep read access to everything and write access only where HumHub needs it.
EOF
if confirm "Apply this ownership change?"; then
  sudo usermod -aG www-data deploy
  sudo chown -R deploy:www-data "$APP"
  sudo find "$APP" -type d -exec chmod u+rwx,g+rxs,g-w,o+rx,o-w {} +
  sudo find "$APP" -type f -exec chmod u+rw,g+r,g-w,o+r,o-w {} +
  for d in "${WRITABLE[@]}"; do
    [[ -d "$APP/$d" ]] || { warn "missing $d (skipped)"; continue; }
    sudo chown -R www-data:www-data "$APP/$d"
    sudo chmod -R g+rwX "$APP/$d"
    sudo find "$APP/$d" -type d -exec chmod g+s {} +
    ok "writable: $d"
  done
  ok "ownership applied"
else
  warn "Skipped. Auto-deploy needs deploy to own $APP/.git — re-run when ready."; exit 1
fi

# ---------------------------------------------------------------------------
step "3. Protect server-local config"
cd "$APP"
git config core.fileMode false           # permission bits never count as code changes
for f in "${LOCAL_CONFIG[@]}"; do
  [[ -f "$f" ]] && git update-index --skip-worktree "$f" && ok "skip-worktree: $f"
done
if ! git diff --quiet; then
  warn "Other tracked files are modified on the server:"; git status --short --untracked-files=no
  warn "Resolve these (tell Claude what they are) before continuing."; exit 1
fi

# ---------------------------------------------------------------------------
step "4. Git remote + branch $BRANCH"
git remote set-url origin "$REPO_URL"
git fetch --quiet origin "$BRANCH"
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
  git checkout --quiet "$BRANCH" 2>/dev/null || git checkout --quiet -b "$BRANCH" "origin/$BRANCH"
fi
git branch --quiet --set-upstream-to="origin/$BRANCH" "$BRANCH"
git merge --ff-only --quiet "origin/$BRANCH"
ok "on $BRANCH @ $(git rev-parse --short HEAD) — $(git log -1 --format=%s)"

# ---------------------------------------------------------------------------
step "5. Install deploy script"
mkdir -p "$CI_DIR/logs"
install -m 0755 "$APP/deploy/remote-deploy.sh" "$CI_DIR/remote-deploy.sh"
ok "$CI_DIR/remote-deploy.sh"

# ---------------------------------------------------------------------------
step "6. sudoers rule (deploy -> www-data, HumHub console only)"
tmp=$(mktemp)
cat > "$tmp" <<'EOF'
# Agoralo CI: deploy may run HumHub console commands as www-data. Nothing else.
deploy ALL=(www-data) NOPASSWD: /usr/bin/php /var/www/agoralo/protected/yii *
EOF
sudo visudo -cf "$tmp" >/dev/null
sudo install -m 0440 -o root -g root "$tmp" "$SUDOERS"
rm -f "$tmp"
sudo -n -u www-data /usr/bin/php "$APP/protected/yii" help >/dev/null && ok "$SUDOERS works"

# ---------------------------------------------------------------------------
step "7. Dedicated CI SSH key (append-only)"
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
PRIV=""
if grep -q " $KEY_COMMENT\$" ~/.ssh/authorized_keys; then
  warn "A '$KEY_COMMENT' key already exists — not generating another."
  warn "To rotate: delete that one line in ~/.ssh/authorized_keys yourself, then re-run."
else
  kd=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -C "$KEY_COMMENT" -f "$kd/key"
  cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-$(date +%Y%m%d-%H%M%S)
  printf 'restrict,command="%s" %s\n' "$CI_DIR/remote-deploy.sh" "$(cat "$kd/key.pub")" >> ~/.ssh/authorized_keys
  PRIV=$(cat "$kd/key")
  shred -u "$kd/key" 2>/dev/null || rm -f "$kd/key"; rm -rf "$kd"
  ok "key appended (restricted to remote-deploy.sh); backup of authorized_keys kept"
fi

# ---------------------------------------------------------------------------
step "8. GitHub secrets  →  github.com/hellasangel/agoralo → Settings → Secrets and variables → Actions"
PORT=$(sudo sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'); PORT=${PORT:-22}
HOSTKEY=$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)
if [[ "$PORT" == 22 ]]; then KH="$PUBLIC_IP $HOSTKEY"; else KH="[$PUBLIC_IP]:$PORT $HOSTKEY"; fi
echo "    DEPLOY_HOST         = $PUBLIC_IP"
echo "    DEPLOY_PORT         = $PORT"
echo "    DEPLOY_USER         = deploy"
echo "    DEPLOY_KNOWN_HOSTS  = $KH"
if [[ -n "$PRIV" ]]; then
  echo "    DEPLOY_SSH_KEY      = (everything between the lines, including BEGIN/END)"
  # Printed straight to the terminal (not through tee), so it never lands in the log file.
  { echo "-----8<---------------------------------------------------------------"
    printf '%s\n' "$PRIV"
    echo "----------------------------------------------------------------8<----"; } > /dev/tty
  warn "Private key shown ONCE on screen; it is not stored on the server or in the log. Do not paste it in chat."
fi
PRIV=""

# ---------------------------------------------------------------------------
step "9. Firewall (read-only check — nothing is changed)"
if command -v ufw >/dev/null; then sudo ufw status | sed 's/^/    /'; else echo "    ufw not installed"; fi
cat <<EOF
    GitHub Actions connects from changing GitHub IP ranges to port $PORT.
    If SSH is restricted to your own IP (ufw or Hetzner Cloud Firewall), auto-deploy
    will time out. Tell Claude before changing any rule — there are alternatives.
EOF

step "Test deploy run (pull is a no-op, then migrate + cache flush + local HTTPS check)"
bash "$CI_DIR/remote-deploy.sh"

printf '\n\033[1;32mDone. Add the secrets above on GitHub, then tell Claude to trigger the first deploy.\033[0m\n'
echo "Log: $LOG"
echo "Note: log out and back in once so 'deploy' picks up its new www-data group membership."
