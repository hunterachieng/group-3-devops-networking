# Shared image for all three services (Order, Inventory, Payment).
# Each service runs this same image with a different `command` in compose -
# they only differ by which app.py they launch and their env vars.

FROM python:3.12-slim

# curl is needed for container healthchecks and the in-network discovery tests.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Run as a non-root user (mirrors the dedicated service account on the VM).
RUN useradd --system --create-home appuser

WORKDIR /app

# Install deps first so this layer caches when only app code changes.
COPY psenv/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code (services/common + the three services).
COPY psenv/services ./services

# In containers, network isolation (not loopback binding) provides protection,
# so services bind all interfaces INSIDE their container. PYTHONUNBUFFERED makes
# stdout logs appear immediately in `docker compose logs`.
ENV BIND_HOST=0.0.0.0 \
    PYTHONUNBUFFERED=1

USER appuser

# All three ports are documented here because this shared image is used by
# order (3001), inventory (3002), and payment (3003). The actual port bound
# at runtime is controlled by the command/env in docker-compose.yml.
EXPOSE 3001 3002 3003

# Default command; overridden per service in docker-compose.yml.
CMD ["python", "services/order/app.py"]
