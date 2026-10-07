from datetime import UTC, datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from shiptrack.domain.models import EventIn, ShipmentCreate, TrackView, format_utc
from shiptrack.domain.status import Status


def test_format_utc_uses_a_z_suffix() -> None:
    assert format_utc(datetime(2026, 10, 1, 12, 0, tzinfo=UTC)) == "2026-10-01T12:00:00Z"


def test_offsets_are_normalized_to_utc() -> None:
    body = ShipmentCreate(
        carrier_code="ACME",
        origin="A",
        destination="B",
        promised_delivery_at="2026-10-01T14:00:00+02:00",  # type: ignore[arg-type]
    )
    assert body.promised_delivery_at == datetime(2026, 10, 1, 12, 0, tzinfo=UTC)
    assert body.promised_delivery_at.utcoffset() == timedelta(0)


def test_naive_timestamps_are_rejected() -> None:
    with pytest.raises(ValidationError):
        ShipmentCreate(
            carrier_code="ACME",
            origin="A",
            destination="B",
            promised_delivery_at="2026-10-01T12:00:00",  # type: ignore[arg-type]
        )


def test_unknown_fields_are_rejected() -> None:
    with pytest.raises(ValidationError):
        ShipmentCreate.model_validate(
            {
                "carrier_code": "ACME",
                "origin": "A",
                "destination": "B",
                "promised_delivery_at": "2026-10-01T12:00:00Z",
                "surprise": 1,
            }
        )


def test_created_is_not_an_event_type() -> None:
    with pytest.raises(ValidationError):
        EventIn.model_validate(
            {"event_type": "CREATED", "location": "X", "occurred_at": "2026-10-01T12:00:00Z"}
        )


def test_json_serialization_uses_z_timestamps() -> None:
    view = TrackView(
        tracking_number="MF0000000001",
        carrier_code="ACME",
        status=Status.IN_TRANSIT,
        estimated_delivery_at=datetime(2026, 10, 3, 1, 2, 3, tzinfo=timezone(timedelta(hours=2))),
        delivered_at=None,
        events=[],
    )
    dumped = view.model_dump(mode="json")
    assert dumped["estimated_delivery_at"] == "2026-10-02T23:02:03Z"
    assert dumped["delivered_at"] is None
