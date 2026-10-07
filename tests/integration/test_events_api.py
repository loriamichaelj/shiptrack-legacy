import logging
import uuid
from collections.abc import Callable
from datetime import timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text

from .conftest import NOW, drain, iso

MakeShipment = Callable[..., dict[str, Any]]
SendEvent = Callable[..., Any]
H = timedelta(hours=1)
T0 = NOW - timedelta(days=1)


def shipment_row(engine: Engine, shipment_id: str) -> Any:
    with engine.connect() as connection:
        return connection.execute(
            text("SELECT * FROM shiptrack.shipments WHERE id = :id"), {"id": shipment_id}
        ).one()


def event_rows(engine: Engine, shipment_id: str) -> list[Any]:
    with engine.connect() as connection:
        return list(
            connection.execute(
                text(
                    "SELECT event_type, applied, idempotency_key FROM shiptrack.tracking_events "
                    "WHERE shipment_id = :id ORDER BY id"
                ),
                {"id": shipment_id},
            )
        )


def test_accepts_with_202(client: TestClient, make_shipment: MakeShipment) -> None:
    shipment = make_shipment()
    response = client.post(
        f"/api/v1/shipments/{shipment['id']}/events",
        headers={"Idempotency-Key": "key-1"},
        json={"event_type": "PICKED_UP", "location": "Rotterdam", "occurred_at": iso(T0)},
    )
    assert response.status_code == 202
    assert response.json() == {"accepted": True, "idempotency_key": "key-1"}
    drain(client)


def test_full_lifecycle(engine: Engine, make_shipment: MakeShipment, send_event: SendEvent) -> None:
    shipment = make_shipment()
    sid = shipment["id"]
    send_event(sid, "PICKED_UP", T0)
    row = shipment_row(engine, sid)
    assert (row.status, row.estimated_delivery_at) == ("PICKED_UP", T0 + timedelta(hours=72))

    send_event(sid, "IN_TRANSIT", T0 + H)
    row = shipment_row(engine, sid)
    assert (row.status, row.estimated_delivery_at) == (
        "IN_TRANSIT",
        T0 + H + timedelta(hours=48),
    )

    send_event(sid, "OUT_FOR_DELIVERY", T0 + 2 * H)
    row = shipment_row(engine, sid)
    assert row.estimated_delivery_at == T0 + 2 * H + timedelta(hours=8)
    assert row.delivered_at is None

    send_event(sid, "DELIVERED", T0 + 3 * H)
    row = shipment_row(engine, sid)
    assert row.status == "DELIVERED"
    assert row.delivered_at == row.estimated_delivery_at == T0 + 3 * H
    assert row.last_event_at == T0 + 3 * H
    assert [e.applied for e in event_rows(engine, sid)] == [True] * 4


def test_forward_skip_is_allowed(
    engine: Engine, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    sid = make_shipment()["id"]
    send_event(sid, "IN_TRANSIT", T0)
    assert shipment_row(engine, sid).status == "IN_TRANSIT"


def test_exception_and_recovery(
    engine: Engine, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    shipment = make_shipment()
    sid = shipment["id"]
    send_event(sid, "IN_TRANSIT", T0)
    estimate = shipment_row(engine, sid).estimated_delivery_at
    send_event(sid, "EXCEPTION", T0 + H)
    row = shipment_row(engine, sid)
    assert row.status == "EXCEPTION"
    assert row.estimated_delivery_at == estimate + timedelta(hours=24)
    send_event(sid, "OUT_FOR_DELIVERY", T0 + 2 * H)
    assert shipment_row(engine, sid).status == "OUT_FOR_DELIVERY"


def test_exception_from_created_uses_the_promised_time(
    engine: Engine, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    shipment = make_shipment(promised=NOW + timedelta(days=2))
    send_event(shipment["id"], "EXCEPTION", T0)
    row = shipment_row(engine, shipment["id"])
    assert row.estimated_delivery_at == NOW + timedelta(days=2, hours=24)


def test_duplicate_idempotency_key_is_applied_once(
    engine: Engine, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    sid = make_shipment()["id"]
    send_event(sid, "PICKED_UP", T0, key="same")
    send_event(sid, "IN_TRANSIT", T0 + H, key="same")  # same key, different content
    rows = event_rows(engine, sid)
    assert len(rows) == 1
    assert rows[0].event_type == "PICKED_UP"
    assert shipment_row(engine, sid).status == "PICKED_UP"


def test_out_of_order_event_is_stored_but_not_applied(
    engine: Engine, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    sid = make_shipment()["id"]
    send_event(sid, "IN_TRANSIT", T0 + 2 * H)
    send_event(sid, "OUT_FOR_DELIVERY", T0 + H)  # occurred before the applied event
    row = shipment_row(engine, sid)
    assert row.status == "IN_TRANSIT"
    assert row.last_event_at == T0 + 2 * H
    assert [e.applied for e in event_rows(engine, sid)] == [True, False]


def test_invalid_transition_is_stored_but_not_applied(
    engine: Engine,
    make_shipment: MakeShipment,
    send_event: SendEvent,
    caplog: pytest.LogCaptureFixture,
) -> None:
    sid = make_shipment()["id"]
    send_event(sid, "IN_TRANSIT", T0)
    with caplog.at_level(logging.WARNING, logger="shiptrack.events.processor"):
        send_event(sid, "PICKED_UP", T0 + H)  # backward move, later timestamp
    assert shipment_row(engine, sid).status == "IN_TRANSIT"
    assert [e.applied for e in event_rows(engine, sid)] == [True, False]
    assert any("invalid transition" in record.message for record in caplog.records)


def test_nothing_changes_after_delivery(
    engine: Engine, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    sid = make_shipment()["id"]
    send_event(sid, "DELIVERED", T0)
    send_event(sid, "EXCEPTION", T0 + H)
    assert shipment_row(engine, sid).status == "DELIVERED"


def test_missing_idempotency_key_is_400(client: TestClient, make_shipment: MakeShipment) -> None:
    sid = make_shipment()["id"]
    body = {"event_type": "PICKED_UP", "location": "X", "occurred_at": iso(T0)}
    for headers in ({}, {"Idempotency-Key": " "}):
        response = client.post(f"/api/v1/shipments/{sid}/events", headers=headers, json=body)
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "MISSING_IDEMPOTENCY_KEY"


def test_overlong_idempotency_key_is_422(client: TestClient, make_shipment: MakeShipment) -> None:
    sid = make_shipment()["id"]
    body = {"event_type": "PICKED_UP", "location": "X", "occurred_at": iso(T0)}
    ok = client.post(
        f"/api/v1/shipments/{sid}/events", headers={"Idempotency-Key": "k" * 64}, json=body
    )
    assert ok.status_code == 202
    too_long = client.post(
        f"/api/v1/shipments/{sid}/events", headers={"Idempotency-Key": "k" * 65}, json=body
    )
    assert too_long.status_code == 422
    assert too_long.json()["error"]["code"] == "VALIDATION_ERROR"
    drain(client)


def test_unknown_shipment_is_404(client: TestClient) -> None:
    response = client.post(
        f"/api/v1/shipments/{uuid.uuid4()}/events",
        headers={"Idempotency-Key": "k"},
        json={"event_type": "PICKED_UP", "location": "X", "occurred_at": iso(T0)},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


@pytest.mark.parametrize("event_type", ["CREATED", "SIDEWAYS", ""])
def test_bad_event_type_is_422(
    client: TestClient, make_shipment: MakeShipment, event_type: str
) -> None:
    sid = make_shipment()["id"]
    response = client.post(
        f"/api/v1/shipments/{sid}/events",
        headers={"Idempotency-Key": "k"},
        json={"event_type": event_type, "location": "X", "occurred_at": iso(T0)},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_event_payload_is_stored(
    engine: Engine, make_shipment: MakeShipment, client: TestClient
) -> None:
    sid = make_shipment()["id"]
    client.post(
        f"/api/v1/shipments/{sid}/events",
        headers={"Idempotency-Key": "with-payload"},
        json={
            "event_type": "PICKED_UP",
            "location": "X",
            "occurred_at": iso(T0),
            "payload": {"driver": "A. Rivera"},
        },
    )
    drain(client)
    with engine.connect() as connection:
        payload = connection.scalar(
            text(
                "SELECT payload FROM shiptrack.tracking_events "
                "WHERE idempotency_key = 'with-payload'"
            )
        )
    assert payload == {"driver": "A. Rivera"}
