import re
import uuid
from collections.abc import Callable
from typing import Any

from fastapi.testclient import TestClient

from .conftest import NOW, iso

MakeShipment = Callable[..., dict[str, Any]]


def test_create_returns_a_shipment_with_a_location_header(client: TestClient) -> None:
    response = client.post(
        "/api/v1/shipments",
        json={
            "carrier_code": "ACME",
            "origin": "Rotterdam",
            "destination": "Chicago",
            "promised_delivery_at": iso(NOW),
        },
    )
    assert response.status_code == 201
    body = response.json()
    assert response.headers["Location"] == f"/api/v1/shipments/{body['id']}"
    assert re.fullmatch(r"MF\d{10}", body["tracking_number"])
    assert body["status"] == "CREATED"
    assert body["carrier_code"] == "ACME"
    assert body["estimated_delivery_at"] is None
    assert body["delivered_at"] is None
    assert body["sla_breached"] is False
    assert set(body) == {
        "id",
        "tracking_number",
        "carrier_code",
        "origin",
        "destination",
        "status",
        "promised_delivery_at",
        "estimated_delivery_at",
        "delivered_at",
        "sla_breached",
        "created_at",
        "updated_at",
    }
    for field in ("promised_delivery_at", "created_at", "updated_at"):
        assert body[field].endswith("Z")


def test_tracking_numbers_are_unique(make_shipment: MakeShipment) -> None:
    numbers = {make_shipment()["tracking_number"] for _ in range(15)}
    assert len(numbers) == 15


def test_unknown_carrier(client: TestClient) -> None:
    response = client.post(
        "/api/v1/shipments",
        json={
            "carrier_code": "NOPE",
            "origin": "A",
            "destination": "B",
            "promised_delivery_at": iso(NOW),
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "UNKNOWN_CARRIER"


def test_validation_errors_use_the_envelope(client: TestClient) -> None:
    response = client.post("/api/v1/shipments", json={"carrier_code": "ACME"})
    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "VALIDATION_ERROR"
    assert error["request_id"] is None
    assert "origin" in error["message"]


def test_naive_timestamp_is_a_validation_error(client: TestClient) -> None:
    response = client.post(
        "/api/v1/shipments",
        json={
            "carrier_code": "ACME",
            "origin": "A",
            "destination": "B",
            "promised_delivery_at": "2026-10-01T12:00:00",
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_get_shipment(client: TestClient, make_shipment: MakeShipment) -> None:
    created = make_shipment()
    response = client.get(f"/api/v1/shipments/{created['id']}")
    assert response.status_code == 200
    assert response.json() == created


def test_get_unknown_or_malformed_shipment_is_404(client: TestClient) -> None:
    for shipment_id in (str(uuid.uuid4()), "not-a-uuid"):
        response = client.get(f"/api/v1/shipments/{shipment_id}")
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "NOT_FOUND"


def test_list_filters(client: TestClient, make_shipment: MakeShipment) -> None:
    make_shipment("ACME")
    make_shipment("ACME")
    make_shipment("BOLT")
    by_carrier = client.get("/api/v1/shipments", params={"carrier_code": "ACME"}).json()
    assert len(by_carrier["items"]) == 2
    assert {s["carrier_code"] for s in by_carrier["items"]} == {"ACME"}
    assert by_carrier["next_cursor"] is None

    created = client.get("/api/v1/shipments", params={"status": "CREATED"}).json()
    assert len(created["items"]) == 3
    assert client.get("/api/v1/shipments", params={"status": "DELIVERED"}).json()["items"] == []


def test_list_rejects_bad_parameters(client: TestClient) -> None:
    for params in (
        {"limit": 0},
        {"limit": 101},
        {"status": "SIDEWAYS"},
        {"carrier_code": "NOPE"},
        {"cursor": "garbage"},
    ):
        response = client.get("/api/v1/shipments", params=params)
        assert response.status_code == 422, params
        assert "error" in response.json()


def test_keyset_pagination_visits_every_shipment_once(
    client: TestClient, make_shipment: MakeShipment
) -> None:
    expected = {make_shipment()["id"] for _ in range(25)}
    seen: list[str] = []
    cursor: str | None = None
    pages = 0
    while True:
        params: dict[str, Any] = {"limit": 10}
        if cursor:
            params["cursor"] = cursor
        page = client.get("/api/v1/shipments", params=params).json()
        seen.extend(item["id"] for item in page["items"])
        pages += 1
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert pages == 3
    assert len(seen) == len(set(seen)) == 25
    assert set(seen) == expected


def test_default_limit_is_twenty(client: TestClient, make_shipment: MakeShipment) -> None:
    for _ in range(21):
        make_shipment()
    page = client.get("/api/v1/shipments").json()
    assert len(page["items"]) == 20
    assert page["next_cursor"] is not None
