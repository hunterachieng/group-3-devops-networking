import pytest
from unittest.mock import patch, MagicMock
import requests as req_lib

from services.order.app import app


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
    assert data["service"] == "order-service"


def test_ready_inventory_up(client):
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    with patch("services.order.app.requests.get", return_value=mock_resp):
        r = client.get("/ready")
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "ready"
    assert data["dependencies"]["inventory"] is True


def test_ready_inventory_down(client):
    with patch("services.order.app.requests.get",
               side_effect=req_lib.exceptions.ConnectionError("unreachable")):
        r = client.get("/ready")
    assert r.status_code == 503
    data = r.get_json()
    assert data["status"] == "not_ready"
    assert data["dependencies"]["inventory"] is False


def test_checkout_success(client):
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {"outcome": "success", "confirm": "sent"}
    mock_resp.raise_for_status = MagicMock()
    with patch("services.order.app.requests.post", return_value=mock_resp):
        r = client.post(
            "/checkout",
            json={"items": ["SKU-1"], "amount": 100},
            content_type="application/json",
        )
    assert r.status_code == 200
    data = r.get_json()
    assert data["outcome"] == "success"
    assert "pipeline" in data


def test_checkout_inventory_down(client):
    with patch("services.order.app.requests.post",
               side_effect=req_lib.exceptions.ConnectionError("inventory down")):
        r = client.post(
            "/checkout",
            json={"items": ["SKU-1"], "amount": 100},
            content_type="application/json",
        )
    assert r.status_code == 502
    data = r.get_json()
    assert data["outcome"] == "failure"
    assert "inventory" in data["error"]


def test_confirm(client):
    r = client.post(
        "/confirm",
        json={"order_id": "ORD-TEST", "amount": 100, "confirmed_by": "payment-service"},
        content_type="application/json",
    )
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "confirmed"


def test_unknown_route(client):
    r = client.get("/nonexistent")
    assert r.status_code == 404
