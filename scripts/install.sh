#!/usr/bin/env bash
#
# install.sh - one-command deploy of the e-commerce service environment.
#
# Idempotent: safe to re-run to redeploy new code (it restarts services to pick
# up changes). Works on any teammate's VM regardless of username or clone path,
# because it locates the repo relative to itself.
#
#   bash scripts/install.sh
#
# Options (environment variables):
#   SKIP_FIREWALL=1   do not configure ufw (e.g. if you manage it separately)
#
# Run as a NORMAL user - it uses sudo internally. Do not run with `sudo bash`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DEPLOY_DIR="/opt/psenv"
SVC_USER="psenv"

step(){ printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

if [ "$(id -u)" = "0" ]; then
  echo "Please run as a normal user (the script uses sudo internally), not with sudo." >&2
  exit 1
fi

# Must run inside a Linux/systemd environment (an Ubuntu VM), not the host OS.
if [ "$(uname -s)" != "Linux" ] || ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
  echo "This must run inside an Ubuntu VM (needs Linux + apt + systemd), not on your host." >&2
  echo "macOS/Windows are for editing only. See docs/SETUP.md Step 1 to get a VM." >&2
  exit 1
fi

# sanity: are we actually in the repo?
for d in psenv systemd nginx scripts; do
  [ -d "$REPO_ROOT/$d" ] || { echo "Cannot find '$d' under $REPO_ROOT - run from the repo." >&2; exit 1; }
done

step "1/8 Installing base packages"
sudo apt-get update -q
sudo apt-get install -y python3-venv python3-pip curl rsync nginx ufw

step "2/8 Service-discovery names in /etc/hosts"
for n in order inventory payment; do
  if grep -q "${n}.internal" /etc/hosts; then
    echo "  ${n}.internal already present"
  else
    echo "127.0.0.1 ${n}.internal" | sudo tee -a /etc/hosts >/dev/null
    echo "  added ${n}.internal"
  fi
done

step "3/8 Service account '${SVC_USER}'"
if id "$SVC_USER" >/dev/null 2>&1; then
  echo "  ${SVC_USER} already exists"
else
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
  echo "  created ${SVC_USER}"
fi

step "4/8 Deploying application to ${DEPLOY_DIR}"
sudo mkdir -p "$DEPLOY_DIR"
# --delete cleans out stale files; excluded paths are preserved (incl. the venv)
sudo rsync -a --delete --exclude '.venv' --exclude '__pycache__' \
  "$REPO_ROOT/psenv/" "$DEPLOY_DIR/"

step "5/8 Python environment"
if [ ! -x "$DEPLOY_DIR/.venv/bin/python" ]; then
  sudo python3 -m venv "$DEPLOY_DIR/.venv"
fi
sudo "$DEPLOY_DIR/.venv/bin/pip" install --quiet --upgrade pip
sudo "$DEPLOY_DIR/.venv/bin/pip" install --quiet -r "$DEPLOY_DIR/requirements.txt"
sudo chmod +x "$DEPLOY_DIR/scripts/wait-for-deps.sh"
sudo chown -R "$SVC_USER:$SVC_USER" "$DEPLOY_DIR"

step "6/8 systemd units (enable on boot + (re)start)"
sudo cp "$REPO_ROOT"/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable inventory.service payment.service order.service
sudo systemctl restart inventory.service payment.service order.service

step "7/8 Nginx reverse proxy"
sudo cp "$REPO_ROOT/nginx/reverse-proxy.conf" /etc/nginx/sites-available/ecommerce.conf
sudo ln -sf /etc/nginx/sites-available/ecommerce.conf /etc/nginx/sites-enabled/ecommerce.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload-or-restart nginx
sudo systemctl enable nginx

step "8/8 Firewall"
if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
  echo "  skipped (SKIP_FIREWALL=1)"
else
  sudo bash "$REPO_ROOT/scripts/setup-firewall.sh"
fi

step "Verifying the deployment"
sleep 2
bash "$REPO_ROOT/scripts/verify.sh"
