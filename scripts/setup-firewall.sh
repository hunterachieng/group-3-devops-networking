#!/usr/bin/env bash
#
# setup-firewall.sh
#
# Defense-in-depth. The PRIMARY protection is that every service binds to
# 127.0.0.1 (loopback), so Inventory and Payment cannot accept connections
# from other machines at all. This firewall is the SECOND layer: it blocks
# everything inbound except SSH and the public HTTP port, so even if a service
# were ever misconfigured to bind publicly, the firewall still stops it.
#
# Run on the VM:  sudo bash setup-firewall.sh
#
# SAFETY: SSH is allowed FIRST so you never lock yourself out of the VM.

set -euo pipefail

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw not found; installing..."
  apt-get update -q && apt-get install -y ufw
fi

# 1. Allow SSH BEFORE enabling anything else (lockout protection).
ufw allow OpenSSH

# 2. Allow the one public port: Nginx on 80.
ufw allow 80/tcp comment 'Nginx public entrypoint (Order)'

# 3. Default: drop all other inbound, permit outbound.
#    This is what blocks 3001/3002/3003 from the outside world.
ufw default deny incoming
ufw default allow outgoing

# 4. Activate.
ufw --force enable

echo
echo "Firewall is active. Current rules:"
ufw status verbose

cat <<'NOTE'

Note on inter-service traffic:
  ufw does NOT filter loopback (127.0.0.1) traffic, so Order -> Inventory ->
  Payment calls and Nginx -> Order all keep working. Only EXTERNAL inbound
  traffic is affected.

Note for Lima/VM users:
  Access to this VM (e.g. `limactl shell`) goes over SSH, which is allowed
  above, so you keep your shell. If anything ever goes wrong, you can recover
  from the host with `limactl stop <vm> && limactl start <vm>`, or disable the
  firewall with `sudo ufw disable`.
NOTE
