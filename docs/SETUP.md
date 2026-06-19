# Team setup guide

How to get a working copy of this system running on your own Ubuntu VM.
Everyone on the team follows this once. It should take ~10 minutes.

If you get stuck at any step, the fix almost always belongs in this doc or in
`install.sh` — note it down, because "a stranger can deploy from our docs" is
part of the grade.

---

## What the system is

A small e-commerce checkout pipeline made of three HTTP services:

| Role      | Service identity   | Discovery name       | Port | Public? | Endpoint        |
|-----------|--------------------|----------------------|------|---------|-----------------|
| Order     | order-service      | order.internal       | 3001 | yes     | POST /checkout  |
| Inventory | inventory-service  | inventory.internal   | 3002 | no      | POST /reserve   |
| Payment   | payment-service    | payment.internal     | 3003 | no      | POST /charge    |

Flow: `client -> Order -> Inventory -> Payment -> (confirm callback) -> Order`.
Every service also has `GET /health`. Only Order is reachable from outside.

---

## The mental model (read this first)

- **You EDIT on your own machine** (Mac/Windows/Linux), in your editor.
- **The system RUNS on an Ubuntu VM.**
- **git connects the two.** You push from your machine; you pull on the VM.

```
EDIT (your machine, VS Code)  --git push-->  GitHub  --git pull-->  RUN (Ubuntu VM)
```

You will have the repo cloned in **two** places: once on your machine (to edit)
and once on the VM (to run). That is intentional. Never edit the VM's copy by
hand — it only ever receives `git pull`.

---

## Step 1 — Get an Ubuntu VM

Depends on your laptop's OS. Use the **course's** setup guide for your platform
(`setup-macos.md`, `setup-linux.md`, `setup-windows.md` in the lab repo).

- **macOS:** install Lima, `limactl start` the lab VM, enter with
  `limactl shell <vm-name>` (`limactl list` shows the name).
- **Linux:** easiest is Multipass — `multipass launch --name opslab` then
  `multipass shell opslab`. Don't run this project on your daily laptop; it
  creates system services and firewall rules.
- **Windows:** WSL2 with Ubuntu, or the course's Windows guide.

You're ready once your prompt shows you're inside an Ubuntu VM (e.g.
`...@linux-ops-lab` with a `$`, not `%`).

---

## Step 2 — Install base tooling (on the VM)

Minimal Ubuntu images ship without the venv module and pip:

```bash
sudo apt update
sudo apt install -y git python3-venv python3-pip
```

---

## Step 3 — Clone the repo (on the VM)

```bash
git clone https://github.com/hunterachieng/group-3-devops-networking.git ~/group-3-devops-networking
cd ~/group-3-devops-networking/psenv
```

(HTTPS clones a public repo with no credentials. You only need GitHub auth to
`git push`, which you do from your own machine, not the VM.)

Sanity check — you should see exactly these files:

```bash
find . -type f -not -path '*/.venv/*'
```

Expected:

```
./requirements.txt
./services/common/__init__.py
./services/common/logging_setup.py
./services/order/app.py
./services/inventory/app.py
./services/payment/app.py
```

---

## Step 4 — Create the Python environment (on the VM)

```bash
python3 -m venv .venv
source .venv/bin/activate          # prompt should now show (.venv)
pip install -r requirements.txt
```

---

## Step 5 — Add the service-discovery names (on the VM)

Services talk by name, not IP. On a single VM these all resolve to loopback:

```bash
echo '127.0.0.1 order.internal
127.0.0.1 inventory.internal
127.0.0.1 payment.internal' | sudo tee -a /etc/hosts

getent hosts inventory.internal      # should print: 127.0.0.1  inventory.internal
```

---

## Step 6 — Run and verify (on the VM)

Started by hand for now; systemd will manage them properly later. (These
background jobs die when you close the terminal — that's expected.)

```bash
SERVICE_PORT=3003 python services/payment/app.py &
SERVICE_PORT=3002 python services/inventory/app.py &
SERVICE_PORT=3001 python services/order/app.py &
sleep 2

curl -s http://127.0.0.1:3001/health
curl -s -X POST http://127.0.0.1:3001/checkout -H 'Content-Type: application/json' -d '{"items":["BOOK-42"],"amount":3500}'
```

Success returns nested JSON with an `order_id` and `"outcome": "success"`.
Stop the manual services with:

```bash
pkill -f 'services/'
```

---

## The daily workflow (everyone)

1. Edit on your own machine (VS Code), on your machine's clone.
2. `git pull` first, make your change.
3. `git add . && git commit -m "..."` then `git push`.
4. On the VM: `cd ~/group-3-devops-networking && git pull`.
5. Redeploy / restart and test.

**The VM never gets hand-edited.** If it runs on the VM but isn't in git, it
doesn't exist as far as the team is concerned.

---

## Troubleshooting setup

- `python3 -m venv` says *ensurepip is not available* → skipped Step 2;
  run `sudo apt install -y python3-venv`.
- `ModuleNotFoundError: common` → wrong directory; you must be in `psenv/`.
- `curl` connection refused → a service didn't start; run the three in separate
  terminals (not backgrounded) to see startup logs.
- Port already in use → `sudo ss -ltnp | grep -E ':(3001|3002|3003)'`.
- `getent hosts inventory.internal` returns nothing → skipped Step 5.
