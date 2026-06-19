# Network security

How Inventory and Payment are kept unreachable from outside the VM, and how to
prove it. This section answers the four questions the assignment requires:
why, what mechanism, how to verify, how to troubleshoot.

---

## Why the services are protected

Inventory and Payment are internal infrastructure. Only the Order service,
fronted by Nginx, is meant to face users. Exposing Inventory or Payment would
let anyone skip Order's logic and call them directly - e.g. trigger a charge
without an order, or reserve stock with no checkout - and would widen the
attack surface for no benefit.

---

## What mechanism enforces it (two layers)

**Primary: loopback binding.** Every service starts with `BIND_HOST=127.0.0.1`
(set in the systemd units). A process bound to the loopback interface can only
accept connections that originate on the VM itself; the kernel will not accept a
connection to `127.0.0.1` arriving from another machine. So Inventory and
Payment are unreachable externally by construction - there is no firewall rule
to forget, because they never listen on a public address in the first place.
Order is also loopback-bound; it is reached only through Nginx.

**The single public door: Nginx.** Nginx binds `0.0.0.0:80` and proxies only to
Order. It is the one process listening on a public address, and it has no route
to Inventory or Payment.

**Secondary: ufw firewall (defense-in-depth).** `scripts/setup-firewall.sh`
sets `deny incoming` by default and allows only SSH and port 80. Even if a
service were one day misconfigured to bind publicly, the firewall would still
block external access to it. ufw does not filter loopback traffic, so the
internal service-to-service calls are unaffected.

---

## Deploy

```bash
# Loopback binding is already in place (BIND_HOST=127.0.0.1 in the units).
# Add the firewall as the second layer:
sudo bash ~/group-3-devops-networking/scripts/setup-firewall.sh
```

---

## How to verify

The one-command proof:

```bash
bash ~/group-3-devops-networking/scripts/verify.sh
```

Section 5 of its output is the key evidence: it tries to reach ports
3001/3002/3003 on the VM's own **public** IP and they must all be refused, while
port 80 answers. Because the services bind to loopback, the VM cannot reach them
on its public IP - and neither can anyone else.

Manual checks if you want to show the raw evidence:

```bash
# 1. Prove WHAT they listen on: internal services show 127.0.0.1, Nginx shows 0.0.0.0
sudo ss -ltnp | grep -E ':(80|3001|3002|3003)'

# 2. Prove the public IP cannot reach an internal service (run ON the VM)
VM_IP=$(hostname -I | awk '{print $1}')
curl -m3 http://$VM_IP:3002/health      # -> Connection refused  (Inventory sealed)
curl -m3 http://$VM_IP/checkout -d '{}'  # -> works              (Order via Nginx)

# 3. Show the firewall rules
sudo ufw status verbose
```

From a SECOND machine (e.g. the instructor's laptop on the same network), the
equivalent test is `curl http://<vm-ip>:3002/health` (must fail) versus
`curl http://<vm-ip>/checkout` (must work).

---

## How to troubleshoot connectivity

- **Inventory/Payment unexpectedly reachable from outside** → a service is
  binding publicly. Check `sudo ss -ltnp | grep 300`; the local address must be
  `127.0.0.1`, not `0.0.0.0`. Fix `BIND_HOST=127.0.0.1` in the unit, then
  `daemon-reload` and restart.
- **Inter-service calls failing after enabling the firewall** → ufw normally
  permits loopback; confirm with `sudo ufw status verbose` that there is no rule
  denying `lo`. Service-to-service traffic is all on 127.0.0.1.
- **Locked out of the VM after enabling ufw** → SSH was not allowed. Recover via
  the host: `limactl stop <vm> && limactl start <vm>`, then
  `sudo ufw allow OpenSSH`. (The script allows SSH first to prevent this.)
- **Port 80 refused from outside but services are up** → the firewall is denying
  80, or Nginx isn't running. Check `sudo ufw status` for the `80/tcp` allow and
  `systemctl status nginx`.
- **`curl` to the public IP hangs instead of refusing** → a firewall is dropping
  (not rejecting) packets; that is still "sealed", just silent. A timeout is a
  pass for the internal ports.
