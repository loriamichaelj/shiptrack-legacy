from collections.abc import Callable
from datetime import timedelta
from typing import Any

from fastapi.testclient import TestClient

from .conftest import NOW

MakeShipment = Callable[..., dict[str, Any]]
SendEvent = Callable[..., Any]
H = timedelta(hours=1)
T0 = NOW - timedelta(days=1)


def test_track_view_has_no_internal_ids(
    client: TestClient, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    shipment = make_shipment()
    send_event(shipment["id"], "PICKED_UP", T0, location="Rotterdam")
    response = client.get(f"/api/v1/track/{shipment['tracking_number']}")
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {
        "tracking_number",
        "carrier_code",
        "status",
        "estimated_delivery_at",
        "delivered_at",
        "events",
    }
    assert body["tracking_number"] == shipment["tracking_number"]
    assert body["status"] == "PICKED_UP"
    assert body["events"] == [
        {
            "event_type": "PICKED_UP",
            "location": "Rotterdam",
            "occurred_at": T0.isoformat().replace("+00:00", "Z"),
        }
    ]
    assert shipment["id"] not in response.text


def test_only_applied_events_appear_in_time_order(
    client: TestClient, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    shipment = make_shipment()
    sid = shipment["id"]
    send_event(sid, "PICKED_UP", T0)
    send_event(sid, "OUT_FOR_DELIVERY", T0 + 3 * H)
    send_event(sid, "IN_TRANSIT", T0 + H)  # out of order: stored, not shown
    send_event(sid, "PICKED_UP", T0 + 4 * H)  # invalid: stored, not shown
    send_event(sid, "DELIVERED", T0 + 5 * H)
    events = client.get(f"/api/v1/track/{shipment['tracking_number']}").json()["events"]
    assert [e["event_type"] for e in events] == ["PICKED_UP", "OUT_FOR_DELIVERY", "DELIVERED"]
    times = [e["occurred_at"] for e in events]
    assert times == sorted(times)


def test_delivered_shipment(
    client: TestClient, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    shipment = make_shipment()
    send_event(shipment["id"], "DELIVERED", T0)
    body = client.get(f"/api/v1/track/{shipment['tracking_number']}").json()
    assert body["status"] == "DELIVERED"
    assert (
        body["delivered_at"]
        == body["estimated_delivery_at"]
        == T0.isoformat().replace("+00:00", "Z")
    )


def test_unknown_tracking_number_is_404(client: TestClient) -> None:
    for number in ("MF0000000000", "garbage", "mf1234567890"):
        response = client.get(f"/api/v1/track/{number}")
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "NOT_FOUND"
