# Team setup guide

How to get a working copy of this system running on your own Ubuntu VM.
Everyone on the team follows this once. It should take ~10 minutes.

If you get stuck at any step, the fix almost always belongs in this doc or in
`install.sh` — note it down, because "a stranger can deploy from our docs" is
part of the grade.

---

## The mental model (read this first)

- **You EDIT on your own machine** (Mac/Windows/Linux), in your editor.
- **The system RUNS on an Ubuntu VM.**
- **git connects the two.** You push from your machine; you pull on the VM.

```
EDIT (your machine, VS Code)  --git push-->  GitHub  --git pull-->  RUN (Ubuntu VM)
```

You will have the repo cloned in **two** places: once on your machine (to edit)
and once on the VM (to run). That is intentional, not a mistake. Never edit the
VM's copy by hand — it only ever receives `git pull`.

---

## Step 1 — Get an Ubuntu VM

This part depends on your laptop's OS. Use the **course's** setup guide for your
platform (in the `devops-up-100` lab repo): `setup-macos.md`, `setup-linux.md`,
or `setup-windows.md`. That is the same process that created the team's VMs.

Quick summary of what each person does:

- **macOS:** install Lima, then `limactl start` the lab VM definition.
  Enter the VM with `limactl shell <vm-name>` (find the name via `limactl list`).
  Your shell prompt changes to `hunter@linux-ops-lab` (or similar) when you're inside.
- **Linux (native Ubuntu):** easiest is Multipass — `multipass launch --name opslab`
  then `multipass shell opslab`. Do NOT run this project directly on your daily
  laptop; it creates system services and firewall rules you don't want on your
  main machine.
- **Windows:** use WSL2 with Ubuntu, or the course's Windows guide.

You're ready for Step 2 once your terminal prompt shows you're **inside** an
Ubuntu VM (it will say something like `...@linux-ops-lab` and use `$`, not `%`).

---

## Step 2 — Install the base tooling (on the VM)

Minimal Ubuntu images ship without the Python venv module and pip, so install
them first:

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

(HTTPS works for read/clone with no setup because the repo is public. You only
need GitHub credentials if you want to `git push` from the VM, which you usually
won't — push from your own machine instead.)

Sanity check — you should see exactly six files:

```bash
find . -type f -not -path '*/.venv/*'
```

Expected:

```
./requirements.txt
./services/common/__init__.py
./services/common/logging_setup.py
./services/service_a/app.py
./services/service_b/app.py
./services/service_c/app.py
```

---

## Step 4 — Create the Python environment (on the VM)

```bash
python3 -m venv .venv
source .venv/bin/activate          # your prompt should now show (.venv)
pip install -r requirements.txt
```

---

## Step 5 — Add the service-discovery names (on the VM)

The services talk to each other by name, not IP. On a single VM these names all
resolve to loopback:

```bash
echo '127.0.0.1 service-a.internal
127.0.0.1 service-b.internal
127.0.0.1 service-c.internal' | sudo tee -a /etc/hosts
```

Verify:

```bash
getent hosts service-b.internal      # should print: 127.0.0.1  service-b.internal
```

---

## Step 6 — Run the services and verify (on the VM)

For now we start them by hand to confirm everything works. (Later, systemd will
manage them properly — these manual background jobs die when you close the
terminal, which is expected.)

```bash
SERVICE_PORT=3003 python services/service_c/app.py &
SERVICE_PORT=3002 python services/service_b/app.py &
SERVICE_PORT=3001 python services/service_a/app.py &
sleep 2

# health
curl -s http://127.0.0.1:3001/health

# full flow: client -> A -> B -> C -> callback to A
curl -s -X POST http://127.0.0.1:3001/process
```

A successful run returns nested JSON containing a `request_id`, e.g.:

```json
{
  "service": "service-a",
  "request_id": "….",
  "outcome": "success",
  "downstream": { "service": "service-b", "downstream": { "service": "service-c", "callback": "sent" } }
}
```

If you see that, your environment is correct. Stop the manual services with:

```bash
pkill -f 'services/service_'
```

---

## The daily workflow (everyone)

1. Edit on your own machine (VS Code), on your machine's clone.
2. `git pull` first (get teammates' changes), make your change.
3. `git add . && git commit -m "..."` then `git push`.
4. On the VM: `cd ~/group-3-devops-networking && git pull`.
5. Redeploy / restart and test.

Rule of thumb: **the VM never gets hand-edited.** If something runs on the VM
that isn't in git, it doesn't exist as far as the team is concerned.

---

## Troubleshooting setup

- `python3 -m venv` says *ensurepip is not available* → you skipped Step 2;
  run `sudo apt install -y python3-venv`.
- `ModuleNotFoundError: common` → you're running from the wrong directory; you
  must be in `psenv/` so that `services/common` is importable.
- `curl` connection refused → a service didn't start. Run the three commands in
  separate terminals (not backgrounded) to see each service's startup logs.
- Port already in use → check what's there: `sudo ss -ltnp | grep -E ':(3001|3002|3003)'`.
- `getent hosts service-b.internal` returns nothing → you skipped Step 5.
