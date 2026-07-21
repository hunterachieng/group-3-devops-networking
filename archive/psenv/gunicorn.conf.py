"""
Gunicorn config shared by all three services.

Required for Prometheus multiprocess mode (see services/common/metrics.py):
  - on_starting: wipe any metrics files left behind by a previous run.
    `docker compose up` always gets a clean /tmp, but `docker compose
    restart` reuses the same container filesystem, so without this a
    restarted service would double-count against its own pre-restart data.
  - child_exit: when a worker is recycled or crashes mid-run, its files
    must be cleaned up or /metrics keeps reporting counts from a dead PID.
"""
import os

from prometheus_client import multiprocess


def on_starting(server):  # noqa: ARG001 - gunicorn calls with this signature
    multiproc_dir = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
    if not multiproc_dir or not os.path.isdir(multiproc_dir):
        return
    for name in os.listdir(multiproc_dir):
        try:
            os.remove(os.path.join(multiproc_dir, name))
        except OSError:
            pass


def child_exit(server, worker):  # noqa: ARG001 - gunicorn calls with this signature
    multiprocess.mark_process_dead(worker.pid)