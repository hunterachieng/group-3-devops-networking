import pytest
from unittest.mock import patch, MagicMock
import requests as req_lib

from services.payment.app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "ok"
    assert data["service"] == "payment-service"


def test_ready(client):
    r = client.get("/ready")
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "ready"
    assert data["dependencies"] == {}


def test_charge_callback_sent(client):
    mock_resp = MagicMock()
    mock_resp.raise_for_status = MagicMock()
    with patch("services.payment.app.requests.post", return_value=mock_resp):
        r = client.post(
            "/charge",
            json={"order_id": "ORD-TEST", "amount": 100},
            content_type="application/json",
        )
    assert r.status_code == 200
    data = r.get_json()
    assert data["outcome"] == "success"
    assert data["confirm"] == "sent"


def test_charge_callback_fails_gracefully(client):
    # Charge must succeed even when the callback to Order is unreachable.
    with patch("services.payment.app.requests.post",
               side_effect=req_lib.exceptions.ConnectionError("order down")):
        r = client.post(
            "/charge",
            json={"order_id": "ORD-TEST", "amount": 100},
            content_type="application/json",
        )
    assert r.status_code == 200
    data = r.get_json()
    assert data["outcome"] == "success"
    assert data["confirm"] == "failed"


def test_unknown_route(client):
    r = client.get("/nonexistent")
    assert r.status_code == 404
