# Docker Setup Guide

How to install Docker and run the containerized e-commerce pipeline on macOS or Linux.

---

## Installing Docker

### macOS

Install Docker Desktop (includes Docker Engine + Compose V2):

```bash
# Option 1 — Download from https://www.docker.com/products/docker-desktop/
# Choose "Mac with Apple Chip" (M1/M2/M3) or "Mac with Intel Chip".
# Open the .dmg, drag Docker to Applications, launch it, and approve the prompt.

# Option 2 — Install via Homebrew:
brew install --cask docker
open /Applications/Docker.app     # must launch once to finish setup
```

After install, verify:

```bash
docker --version          # Docker version 27.x or later
docker compose version    # Docker Compose version v2.x
```

### Linux (Ubuntu/Debian)

```bash
# Add Docker's official GPG key and repository:
sudo apt update
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

# Install Docker Engine + Compose plugin:
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Let your user run docker without sudo:
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker --version          # Docker version 27.x or later
docker compose version    # Docker Compose version v2.x
```

> **Compose V1 vs V2:** This project uses `docker compose` (space, V2).
> If your machine only has the older `docker-compose` (hyphen, V1), install
> the plugin: `sudo apt install docker-compose-plugin`. All commands in this
> doc use the V2 syntax.

---

## Running the stack

```bash
cd group-3-devops-networking
docker compose up --build -d
docker compose ps          # all four containers should show "healthy"
```

First build takes 1–2 minutes (downloads base image + installs pip packages).
Subsequent builds are faster thanks to layer caching.

### Quick smoke test

```bash
# Health check:
curl -s http://localhost:8080/health | python3 -m json.tool

# Full checkout flow:
curl -s -X POST http://localhost:8080/checkout \
  -H 'Content-Type: application/json' \
  -d '{"items":["SKU-1","SKU-2"],"amount":4200}' | python3 -m json.tool

# Readiness check:
curl -s http://localhost:8080/ready | python3 -m json.tool
```

### Useful commands

```bash
docker compose logs -f              # stream all logs (Ctrl-C to stop)
docker compose logs order           # logs for one service
docker compose down                 # stop and remove containers
docker compose up --build -d        # rebuild after code changes
docker compose restart order        # restart a single service
docker compose stop payment         # stop one service (others keep running)
docker compose start payment        # bring it back
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `docker: command not found` | Docker is not installed — follow the install steps above |
| `docker-compose: command not found` | You have Docker but not Compose V1. Install the V2 plugin: `sudo apt install docker-compose-plugin`, then use `docker compose` (space) |
| `permission denied` on Linux | Run `sudo usermod -aG docker $USER && newgrp docker` |
| `port 8080 already in use` | Something else is on port 8080. Find it: `sudo lsof -i :8080` or change the port in `docker-compose.yml` (`"9090:80"` instead of `"8080:80"`) |
| Build fails on ARM Mac | The `python:3.12-slim` and `nginx:1.27-alpine` images support ARM natively — if you see platform warnings, run `export DOCKER_DEFAULT_PLATFORM=linux/arm64` before building |
| Containers start but show `unhealthy` | Check logs: `docker compose logs <service>`. Common cause: a Python import error or missing dependency |

---

## What's running

After `docker compose up`, four containers are created:

```
client → nginx (localhost:8080) → order:3001 → inventory:3002 → payment:3003
                                     ^                               |
                                     +---- POST /confirm callback ---+
```

- **nginx** — reverse proxy, only container with a published port (8080)
- **order** — public-facing service, receives `/checkout`
- **inventory** — internal, reserves stock
- **payment** — internal, charges customer, confirms back to order

All services run under Gunicorn (`--workers 2 --threads 4`) and log JSON to stdout.

For the full validation test suite, see [CONTAINER_VALIDATION.md](CONTAINER_VALIDATION.md).
