#!/usr/bin/env bash
#
# Agoralo — ONE-TIME server preparation for GitHub Actions auto-deploy.
#
# Run as your normal ADMIN user (the one you log in with, which has sudo) — not as root:
#
#   curl -fsSL https://raw.githubusercontent.com/hellasangel/agoralo/main/deploy/server-setup-ci.sh -o ~/server-setup-ci.sh
#   less ~/server-setup-ci.sh          # review first
#   bash ~/server-setup-ci.sh
#
# It asks for the name of a dedicated deploy user. That name is never stored in
# this (public) repository — only on the server and in the GitHub secret DEPLOY_USER.
#
# Steps (all checks run BEFORE anything is changed; every change is explained;
# it stops on the first error):
#   1. Pre-flight: git clone present, no unexpected local edits, sshd/AllowUsers layout.
#   2. Create the deploy user: no password (key-only), no sudo group, member of www-data.
#   3. [asks] SSH: append the deploy user to the existing AllowUsers line
#      (backup + `sshd -t` validation + reload; your own user stays allowed).
#   4. [asks] Ownership: deploy user owns the code, www-data owns only runtime-writable dirs.
#   5. Git: protect server-local config (skip-worktree), switch to `main` (fast-forward only).
#   6. Install the forced-command deploy script (root-owned, so it can't be altered).
#   7. One narrow sudoers rule: deploy user may run `php protected/yii ...` as www-data.
#   8. Dedicated CI SSH key, bound to the deploy script only (restrict,command=...).
#   9. End-to-end test: SSH to localhost with that key → runs a real deploy.
#  10. Prints the 5 GitHub secrets; the private key is shown once on screen only.
#
# Never disables SSH, never removes keys or users, never changes firewall rules.

set -Eeuo pipefail

APP=/var/www/agoralo
BRANCH=main
REPO_URL=https://github.com/hellasangel/agoralo.git
PUBLIC_IP=2.28.57.50
KEY_COMMENT=agoralo-github-actions
SUDOERS=/etc/sudoers.d/agoralo-deploy
WRITABLE=(assets protected/runtime protected/config protected/modules uploads)
LOCAL_CONFIG=(protected/config/common.php protected/config/web.php protected/config/console.php)
LOG="$HOME/agoralo-setup-ci-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    !!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    STOP  %s\033[0m\n' "$*"; exit 1; }
trap 'printf "\033[1;31mSTOPPED at line %s: %s\nLog: %s\033[0m\n" "$LINENO" "$BASH_COMMAND" "$LOG"; exit 1' ERR
confirm() { local a; read -r -p "    $1 [y/N] " a </dev/tty; [[ "$a" =~ ^[Yy]$ ]]; }

[[ $EUID -ne 0 ]] || die "Run as your normal admin user (the script uses sudo), not as root."
ADMIN=$(id -un)
sudo -v

read -r -p "Name for the dedicated deploy user (e.g. something not guessable): " DU </dev/tty
[[ "$DU" =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] || die "Invalid user name '$DU' (lowercase letters, digits, - or _)."
[[ "$DU" != "$ADMIN" && "$DU" != root && "$DU" != www-data ]] || die "Use a separate, new user name."
PHP_BIN=$(command -v php) || die "php not found in PATH"
GITU() { sudo git -c safe.directory="$APP" -C "$APP" "$@"; }

# ===========================================================================
step "1. Pre-flight checks (nothing is changed yet)"
[[ -d "$APP/.git" ]] || die "$APP is not a git clone."
echo "    branch: $(GITU rev-parse --abbrev-ref HEAD)   commit: $(GITU log --oneline -1)"
echo "    origin: $(GITU remote get-url origin)"
dirty=$(GITU -c core.fileMode=false status --porcelain --untracked-files=no | awk '{print $2}' | grep -vxF -f <(printf '%s\n' "${LOCAL_CONFIG[@]}") || true)
[[ -z "$dirty" ]] || die "Tracked files are modified on the server (besides local config):
$dirty
   Show Claude:  sudo git -C $APP -c safe.directory=$APP diff --stat"
ok "no unexpected local changes"

ALLOW=$(sudo sshd -T | awk '$1=="allowusers"{print $2}')
ALLOW_FILES=$(sudo grep -rlEi '^\s*AllowUsers\s' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || true)
ALLOW_LINES=$(sudo grep -rhEi '^\s*AllowUsers\s' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | wc -l)
if [[ -n "$ALLOW" ]]; then
  echo "    sshd AllowUsers: $(echo $ALLOW)   (in: ${ALLOW_FILES:-?})"
  if ! grep -qxF "$DU" <<<"$ALLOW"; then
    [[ "$ALLOW_LINES" == 1 ]] || die "AllowUsers is defined on $ALLOW_LINES lines/places. Send Claude:  sudo grep -rnEi 'AllowUsers|^\s*Match' /etc/ssh/"
    sudo grep -rqEi '^\s*Match\s' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null && die "sshd uses Match blocks — send Claude:  sudo grep -rnEi 'AllowUsers|^\s*Match' /etc/ssh/"
  fi
else
  echo "    sshd AllowUsers: not set (all users with keys may log in)"
fi
ok "pre-flight passed"

# ===========================================================================
step "2. Deploy user '$DU'"
if id "$DU" >/dev/null 2>&1; then
  ok "user exists"
else
  echo "    Will create '$DU': no password (key-only login), NOT in sudo group, member of www-data."
  confirm "Create user '$DU'?" || die "Cancelled."
  sudo adduser --disabled-password --gecos "Agoralo CI deploy" "$DU" >/dev/null
  ok "created"
fi
sudo usermod -aG www-data "$DU"
grep -qw sudo <<<"$(id -nG "$DU")" && warn "'$DU' is in the sudo group — it should not be. Remove with: sudo deluser $DU sudo"
DH=$(getent passwd "$DU" | cut -d: -f6)
ok "home: $DH, groups: $(id -nG "$DU")"

# ===========================================================================
step "3. SSH access for '$DU'"
if [[ -n "$ALLOW" ]] && ! grep -qxF "$DU" <<<"$ALLOW"; then
  F=$ALLOW_FILES
  cat <<EOF
    sshd only lets these users log in: $(echo $ALLOW)
    Plan: append '$DU' to that same AllowUsers line in $F.
      - a timestamped backup of $F is kept
      - the new config is validated with 'sshd -t' before reload; on failure the backup is restored
      - 'systemctl reload ssh' keeps your current session open; '$ADMIN' stays allowed
      - password login stays disabled; '$DU' has no password anyway
EOF
  confirm "Apply this SSH change?" || die "Cancelled — without it GitHub cannot log in as '$DU'."
  BAK="$F.bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp -a "$F" "$BAK"
  sudo sed -i -E "s/^([[:space:]]*AllowUsers[[:space:]].*[^[:space:]])[[:space:]]*$/\1 $DU/I" "$F"
  if ! sudo sshd -t; then sudo cp -a "$BAK" "$F"; die "sshd -t failed — original config restored, nothing reloaded."; fi
  NEWALLOW=$(sudo sshd -T | awk '$1=="allowusers"{print $2}')
  grep -qxF "$ADMIN" <<<"$NEWALLOW" || { sudo cp -a "$BAK" "$F"; die "Safety check: '$ADMIN' would lose access — restored."; }
  sudo systemctl reload ssh
  ok "AllowUsers now: $(sudo sshd -T | awk '$1=="allowusers"{print $2}' | xargs)  (backup: $BAK)"
  warn "Keep this session open. In a NEW terminal check you can still log in as $ADMIN."
else
  ok "no change needed"
fi

# ===========================================================================
step "4. Ownership"
cat <<EOF
    Now:     $(sudo stat -c '%U:%G' "$APP") owns $APP
    Planned: $DU:www-data owns code, .git and vendor (dirs setgid, www-data read-only)
             www-data:www-data owns ${WRITABLE[*]} (group-writable)
EOF
confirm "Apply ownership change?" || die "Cancelled."
sudo chown -R "$DU:www-data" "$APP"
sudo find "$APP" -type d -exec chmod u+rwx,g+rxs,g-w,o+rx,o-w {} +
sudo find "$APP" -type f -exec chmod u+rw,g+r,g-w,o+r,o-w {} +
for d in "${WRITABLE[@]}"; do
  [[ -d "$APP/$d" ]] || { warn "missing $d (skipped)"; continue; }
  sudo chown -R www-data:www-data "$APP/$d"
  sudo chmod -R g+rwX "$APP/$d"
  sudo find "$APP/$d" -type d -exec chmod g+s {} +
done
ok "ownership applied"

# ===========================================================================
step "5. Git working copy → $BRANCH"
G() { sudo -u "$DU" git -C "$APP" "$@"; }
G config core.fileMode false
for f in "${LOCAL_CONFIG[@]}"; do [[ -f "$APP/$f" ]] && G update-index --skip-worktree "$f"; done
G remote set-url origin "$REPO_URL"
G fetch --quiet origin "$BRANCH"
[[ "$(G rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || G checkout --quiet "$BRANCH"
G branch --quiet --set-upstream-to="origin/$BRANCH" "$BRANCH"
G merge --ff-only --quiet "origin/$BRANCH"
ok "on $BRANCH @ $(G log --oneline -1)"

# ===========================================================================
step "6. Deploy script (forced command)"
sudo install -d -m 0755 -o root -g root "$DH/agoralo-ci"
sudo install -m 0755 -o root -g root "$APP/deploy/remote-deploy.sh" "$DH/agoralo-ci/remote-deploy.sh"
sudo install -d -m 0750 -o "$DU" -g "$DU" "$DH/agoralo-ci/logs"
ok "$DH/agoralo-ci/remote-deploy.sh (root-owned)"

# ===========================================================================
step "7. sudoers: $DU → www-data, HumHub console only"
tmp=$(mktemp)
printf '# Agoralo CI: %s may run HumHub console commands as www-data. Nothing else.\n%s ALL=(www-data) NOPASSWD: %s %s/protected/yii *\n' "$DU" "$DU" "$PHP_BIN" "$APP" > "$tmp"
sudo visudo -cf "$tmp" >/dev/null
sudo install -m 0440 -o root -g root "$tmp" "$SUDOERS"; rm -f "$tmp"
sudo -u "$DU" sudo -n -u www-data "$PHP_BIN" "$APP/protected/yii" help >/dev/null
ok "$SUDOERS works"

# ===========================================================================
step "8. CI SSH key"
AK="$DH/.ssh/authorized_keys"
sudo install -d -m 0755 -o root -g root "$DH/.ssh"
sudo touch "$AK"
KD=$(mktemp -d); chmod 700 "$KD"
cleanup_key() { shred -u "$KD/key" 2>/dev/null || rm -f "$KD/key"; rm -rf "$KD"; }
if sudo grep -q " $KEY_COMMENT\$" "$AK"; then
  warn "A '$KEY_COMMENT' key already exists in $AK — not generating another."
  warn "To rotate: remove that line yourself (sudo nano $AK), then re-run."
  NEWKEY=0
else
  ssh-keygen -q -t ed25519 -N '' -C "$KEY_COMMENT" -f "$KD/key"
  printf 'restrict,command="%s" %s\n' "$DH/agoralo-ci/remote-deploy.sh" "$(cat "$KD/key.pub")" | sudo tee -a "$AK" >/dev/null
  NEWKEY=1
fi
sudo chown root:root "$AK"; sudo chmod 0644 "$AK"
ok "$AK (root-owned; '$DU' cannot add keys)"

# ===========================================================================
step "9. End-to-end test: SSH as $DU with the CI key → real deploy"
if [[ $NEWKEY == 1 ]]; then
  ssh -i "$KD/key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$DU@127.0.0.1" \
    || { cleanup_key; die "SSH test failed — see output above."; }
  ok "GitHub will be able to deploy the same way"
else
  sudo -u "$DU" -H "$DH/agoralo-ci/remote-deploy.sh"
fi

# ===========================================================================
step "10. GitHub secrets → github.com/hellasangel/agoralo/settings/secrets/actions"
HOSTKEY=$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)
PORT=$(sudo sshd -T | awk '$1=="port"{p=$2} END{print p}')   # no early exit: avoids SIGPIPE under pipefail
if [[ "$PORT" == 22 ]]; then KH="$PUBLIC_IP $HOSTKEY"; else KH="[$PUBLIC_IP]:$PORT $HOSTKEY"; fi
{
  echo "    DEPLOY_HOST         = $PUBLIC_IP"
  echo "    DEPLOY_PORT         = $PORT"
  echo "    DEPLOY_USER         = $DU"
  echo "    DEPLOY_KNOWN_HOSTS  = $KH"
  if [[ $NEWKEY == 1 ]]; then
    echo "    DEPLOY_SSH_KEY      = everything between the scissors lines, including BEGIN/END:"
    echo "-----8<---------------------------------------------------------------"
    cat "$KD/key"
    echo "----------------------------------------------------------------8<----"
  fi
} > /dev/tty    # screen only — not written to the log
cleanup_key
warn "The private key is not stored anywhere on the server. Do not paste it in chat."

step "Firewall (read-only)"
sudo ufw status 2>/dev/null | sed 's/^/    /' || echo "    ufw not installed"
echo "    GitHub connects from changing IP ranges to port $PORT — it must stay open to Anywhere."

printf '\n\033[1;32mDone. Add the secrets on GitHub, then tell Claude "έτοιμα τα secrets".\033[0m\nLog: %s\n' "$LOG"
