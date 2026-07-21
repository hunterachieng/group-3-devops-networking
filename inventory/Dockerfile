FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ARG GIT_SHA=dev
ENV GIT_SHA=$GIT_SHA \
    BIND_HOST=0.0.0.0 \
    SERVICE_PORT=3002 \
    PYTHONUNBUFFERED=1 \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus_multiproc

RUN useradd -m appuser \
    && mkdir -p /tmp/prometheus_multiproc \
    && chown appuser /tmp/prometheus_multiproc

USER appuser
EXPOSE 3002

# exec-form CMD => gunicorn is PID 1 and receives SIGTERM for graceful shutdown
CMD ["gunicorn", "--config", "gunicorn.conf.py", "--bind", "0.0.0.0:3002", \
     "--workers", "2", "--graceful-timeout", "30", "app:app"]
