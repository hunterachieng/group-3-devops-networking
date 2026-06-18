"""
Shared logging + tracing helpers used by all three services.

Why this exists:
  The assignment requires structured JSON logs that can answer
  "what happened, when, which service, which request, what outcome".
  Rather than copy-paste a logger into every service, all three
  import from here so the log format is identical everywhere. That
  is what makes a single request greppable across the whole system.

Design notes:
  - Logs are written to STDOUT, not to a file. systemd/journald
    captures stdout automatically, so `journalctl -u service-a`
    just works with no extra plumbing. This is standard practice
    for services managed by systemd.
  - Every line is a single self-contained JSON object (one line =
    one event), which is what log shippers and `jq` expect.
"""

import json
import logging
import sys
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    """Render each log record as a single line of JSON."""

    def __init__(self, service_name: str):
        super().__init__()
        self.service_name = service_name

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            # WHEN did it happen (UTC, ISO-8601, sortable)
            "timestamp": datetime.now(timezone.utc).isoformat(),
            # WHAT was the severity
            "level": record.levelname,
            # WHICH service emitted this
            "service": self.service_name,
            # WHAT happened (human-readable)
            "message": record.getMessage(),
        }

        # WHICH request triggered this (the trace / correlation id)
        request_id = getattr(record, "request_id", None)
        if request_id is not None:
            entry["request_id"] = request_id

        # Any extra structured context (method, path, status, outcome, ...)
        extra_fields = getattr(record, "extra_fields", None)
        if extra_fields:
            entry.update(extra_fields)

        # Full traceback if this was an error
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)

        return json.dumps(entry)


def get_logger(service_name: str) -> logging.Logger:
    """Return a logger that emits JSON lines to stdout."""
    logger = logging.getLogger(service_name)
    logger.setLevel(logging.INFO)

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service_name))

    # Replace any existing handlers so we don't double-log, and
    # don't bubble up to the root logger (which has its own format).
    logger.handlers = [handler]
    logger.propagate = False
    return logger


def log_event(logger: logging.Logger, event: str, message: str = None,
              request_id: str = None, level: int = logging.INFO, **fields):
    """
    Emit one structured event.

    event      : short machine-friendly tag, e.g. "request_received"
    message    : human-readable description (defaults to the event tag)
    request_id : the trace id so this line can be correlated
    fields     : any extra key/values (method, path, status, outcome...)
    """
    extra = {"extra_fields": {"event": event, **fields}}
    if request_id is not None:
        extra["request_id"] = request_id
    logger.log(level, message or event, extra=extra)
