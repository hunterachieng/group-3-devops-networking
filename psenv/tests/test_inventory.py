import pytest
from unittest.mock import patch, MagicMock
import requests as req_lib

from services.inventory.app import app


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
    assert data["service"] == "inventory-service"


def test_ready_payment_up(client):
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch("services.inventory.app.requests.get", return_value=mock_resp):
        r = client.get("/ready")
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "ready"
    assert data["dependencies"]["payment"] is True


def test_ready_payment_down(client):
    with patch("services.inventory.app.requests.get",
               side_effect=req_lib.exceptions.ConnectionError("unreachable")):
        r = client.get("/ready")
    assert r.status_code == 503
    data = r.get_json()
    assert data["status"] == "not_ready"
    assert data["dependencies"]["payment"] is False


def test_reserve_success(client):
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {"outcome": "success", "confirm": "sent"}
    mock_resp.raise_for_status = MagicMock()
    with patch("services.inventory.app.requests.post", return_value=mock_resp):
        r = client.post(
            "/reserve",
            json={"order_id": "ORD-TEST", "items": ["SKU-1"], "amount": 100},
            content_type="application/json",
        )
    assert r.status_code == 200
    data = r.get_json()
    assert data["outcome"] == "success"
    assert "downstream" in data


def test_reserve_payment_down(client):
    with patch("services.inventory.app.requests.post",
               side_effect=req_lib.exceptions.ConnectionError("payment down")):
        r = client.post(
            "/reserve",
            json={"order_id": "ORD-TEST", "items": ["SKU-1"], "amount": 100},
            content_type="application/json",
        )
    assert r.status_code == 502
    data = r.get_json()
    assert data["outcome"] == "failure"
    assert "payment" in data["error"]


def test_unknown_route(client):
    r = client.get("/nonexistent")
    assert r.status_code == 404
