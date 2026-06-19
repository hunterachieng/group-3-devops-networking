# Nginx reverse proxy

Nginx is the single public entry point. It listens on port 80 and forwards
**only** to the Order service. Inventory and Payment have no route through it,
so they are unreachable via the proxy by design.

Run everything below **on the VM**.

---

## Design (for the demo)

- **One door in.** The config has exactly one `location /` block, pointing at
  `order.internal:3001`. There is no block for Inventory or Payment, so port 80
  cannot reach them. "Only Order is public" is enforced by the proxy itself.
- **Trace starts at the front door.** A `map` reuses a client-supplied
  `X-Request-ID` or generates Nginx's built-in `$request_id`, then passes it
  upstream as `X-Request-ID`. So every request is traceable from the very first
  hop, and the Nginx access log records the same `trace=` id as the service logs.
- **Upstream by name.** `proxy_pass http://order.internal:3001` uses the
  discovery name, consistent with the rest of the system (not a hardcoded IP).

---

## Deploy

```bash
sudo apt update && sudo apt install -y nginx

# install our config and enable it (Ubuntu sites-available/enabled pattern)
sudo cp ~/group-3-devops-networking/nginx/reverse-proxy.conf \
        /etc/nginx/sites-available/ecommerce.conf
sudo ln -sf /etc/nginx/sites-available/ecommerce.conf \
            /etc/nginx/sites-enabled/ecommerce.conf

# remove the stock default site so it doesn't shadow ours
sudo rm -f /etc/nginx/sites-enabled/default

# ALWAYS test before reloading - this catches typos safely
sudo nginx -t

sudo systemctl reload nginx       # apply config (no dropped connections)
sudo systemctl enable nginx       # start on boot
```

Order must be reachable at `order.internal:3001` (it is, from /etc/hosts +
the running service).

---

## Verify

```bash
# the public path: client -> Nginx:80 -> Order -> Inventory -> Payment -> confirm
curl -s -X POST http://localhost/checkout \
  -H 'Content-Type: application/json' -d '{"items":["BOOK-42"],"amount":3500}'

curl -s http://localhost/health         # -> order-service ok

# Inventory/Payment are NOT routable through Nginx - there is no location for
# them. Port 80 only ever reaches Order. (Direct access to 3002/3003 is locked
# down separately in the network-security phase.)
```

Confirm the trace originates at Nginx and flows through:

```bash
sudo tail -2 /var/log/nginx/ecommerce_access.log
# -> ... status=200 trace=<id> upstream=127.0.0.1:3001 ...
# the same <id> appears as request_id in the order/inventory/payment JSON logs
```

---

## Operate

```bash
sudo nginx -t                     # test config (do this before every reload)
sudo systemctl reload nginx       # graceful apply of new config
sudo systemctl restart nginx      # full restart (rarely needed)
systemctl status nginx
```

Edit the config in the repo, `git pull` on the VM, re-copy to
`sites-available`, `nginx -t`, then `reload`.

---

## Troubleshooting

- `nginx -t` fails → it prints the file and line; fix and re-test before reload.
- `502 Bad Gateway` → Nginx is up but Order isn't reachable. Check
  `systemctl status order` and `curl http://order.internal:3001/health`.
- `curl localhost` returns the stock Nginx welcome page → the default site is
  still enabled; `sudo rm /etc/nginx/sites-enabled/default` and reload.
- `host not found in upstream "order.internal"` at start → the name isn't in
  `/etc/hosts`; see SETUP.md Step 5. Nginx resolves it at load time.
- Port 80 already in use → `sudo ss -ltnp | grep :80` to find the squatter.
- Changes not taking effect → you edited the file but didn't `reload` (or edited
  `sites-available` but the symlink points elsewhere).
