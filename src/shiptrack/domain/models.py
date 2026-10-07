"""Pydantic schemas for the HTTP API (legacy design §3.4)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated, Any

from pydantic import (
    AfterValidator,
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    PlainSerializer,
    field_validator,
)

from shiptrack.domain.status import Status


def _to_utc(value: datetime) -> datetime:
    return value.astimezone(UTC)


def format_utc(value: datetime) -> str:
    """ISO-8601 in UTC with a Z suffix."""
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


# Timezone-aware on input (naive timestamps are rejected), normalized to UTC, and
# serialized as ISO-8601 with a Z suffix.
UtcDatetime = Annotated[
    AwareDatetime,
    AfterValidator(_to_utc),
    PlainSerializer(format_utc, return_type=str, when_used="json"),
]


class ShipmentCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    carrier_code: str = Field(min_length=1, max_length=8)
    origin: str = Field(min_length=1, max_length=100)
    destination: str = Field(min_length=1, max_length=100)
    promised_delivery_at: UtcDatetime


class ShipmentOut(BaseModel):
    id: uuid.UUID
    tracking_number: str
    carrier_code: str
    origin: str
    destination: str
    status: Status
    promised_delivery_at: UtcDatetime
    estimated_delivery_at: UtcDatetime | None
    delivered_at: UtcDatetime | None
    sla_breached: bool
    created_at: UtcDatetime
    updated_at: UtcDatetime


class ShipmentPage(BaseModel):
    items: list[ShipmentOut]
    next_cursor: str | None


class EventIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    event_type: Status
    location: str = Field(min_length=1, max_length=100)
    occurred_at: UtcDatetime
    payload: dict[str, Any] | None = None

    @field_validator("event_type")
    @classmethod
    def _not_created(cls, value: Status) -> Status:
        if value is Status.CREATED:
            raise ValueError("CREATED is not a valid event type")
        return value


class EventAccepted(BaseModel):
    accepted: bool
    idempotency_key: str


class TrackEvent(BaseModel):
    event_type: Status
    location: str
    occurred_at: UtcDatetime


class TrackView(BaseModel):
    """Public view of a shipment: no internal IDs."""

    tracking_number: str
    carrier_code: str
    status: Status
    estimated_delivery_at: UtcDatetime | None
    delivered_at: UtcDatetime | None
    events: list[TrackEvent]


class PodOut(BaseModel):
    document_id: uuid.UUID
    shipment_id: uuid.UUID
    content_type: str
    size_bytes: int
    sha256: str
    uploaded_at: UtcDatetime
