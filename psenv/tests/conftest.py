"""
Session-wide test setup.

prometheus_client decides single-process vs. multiprocess storage mode
at the moment it is FIRST imported, based on whether
PROMETHEUS_MULTIPROC_DIR is already set in the environment at that
instant - not whenever a test later sets it. Since some other test
module (e.g. test_inventory.py) may import services.common.metrics,
and therefore prometheus_client, before test_metrics.py's own code
runs, the env var has to be set here, in conftest.py, which pytest
always loads before collecting any test module in this directory.
"""
import os
import shutil
import tempfile

_MULTIPROC_DIR = tempfile.mkdtemp(prefix="pytest_prometheus_multiproc_")
os.environ.setdefault("PROMETHEUS_MULTIPROC_DIR", _MULTIPROC_DIR)


def pytest_sessionfinish(session, exitstatus):  # noqa: ARG001
    shutil.rmtree(_MULTIPROC_DIR, ignore_errors=True)