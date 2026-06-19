# Repo update — read before you pull

The repo changed in two big ways since some of you first cloned:

1. The repo history was **reset early on** to remove the course/lab files. If you
   cloned before that, a normal `git pull` will fail or tangle — re-clone instead.
2. The three services were **renamed** to `order`, `inventory`, `payment`
   (previously `service_a/b/c`), and the public endpoint on Order is now
   `POST /checkout`.

---

## Easiest path — re-clone (recommended for everyone)

```bash
cd ~                       # move out of the old folder first
rm -rf group-3-devops-networking
git clone https://github.com/hunterachieng/group-3-devops-networking.git
```

Then follow `docs/SETUP.md` from Step 4 (venv) onward.

---

## If you'd rather keep your existing clone

Only do this if you cloned **recently** (after the history reset) and have no
local work you care about:

```bash
cd group-3-devops-networking
git fetch origin
git reset --hard origin/main      # WARNING: discards local uncommitted changes
git pull
```

`git reset --hard origin/main` forces your clone to exactly match GitHub. It is
safe only because none of us have started personal changes yet — it throws away
uncommitted work.

---

## Two things EVERYONE must redo on their VM

These live on the VM, not in git, so pulling code does not update them.

### 1. Update the discovery names in /etc/hosts

```bash
sudo sed -i '/service-[abc]\.internal/d' /etc/hosts      # remove old names
echo '127.0.0.1 order.internal
127.0.0.1 inventory.internal
127.0.0.1 payment.internal' | sudo tee -a /etc/hosts
```

### 2. Restart the services

A running process keeps the OLD code until you restart it — new files on disk
change nothing until the process is relaunched.

```bash
pkill -f 'services/'
cd ~/group-3-devops-networking/psenv && source .venv/bin/activate
SERVICE_PORT=3003 python services/payment/app.py &
SERVICE_PORT=3002 python services/inventory/app.py &
SERVICE_PORT=3001 python services/order/app.py &
sleep 2
curl -s -X POST http://127.0.0.1:3001/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["BOOK-42"],"amount":3500}'
```

Success looks like `"service": "order-service"` and `"outcome": "success"` with
an `order_id`.

---

## Note

Don't bother perfecting the manual run — systemd is replacing it shortly. You
just need it working **once** to confirm your setup is sound. After that,
starting the services becomes `sudo systemctl start order inventory payment`
for everyone, identically.
