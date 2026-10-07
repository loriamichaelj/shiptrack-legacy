"""Tracking event ingestion."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy.orm import Session

from shiptrack.api.deps import get_shipment_or_404
from shiptrack.api.errors import ApiError
from shiptrack.db.session import get_session
from shiptrack.domain.models import EventAccepted, EventIn
from shiptrack.events.processor import EventProcessor, QueuedEvent

router = APIRouter(prefix="/api/v1")

MAX_KEY_LENGTH = 64


@router.post("/shipments/{shipment_id}/events", status_code=202, response_model=EventAccepted)
def post_event(
    shipment_id: str,
    body: EventIn,
    request: Request,
    session: Annotated[Session, Depends(get_session)],
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> EventAccepted:
    if idempotency_key is None or not idempotency_key.strip():
        raise ApiError(400, "MISSING_IDEMPOTENCY_KEY", "The Idempotency-Key header is required")
    if len(idempotency_key) > MAX_KEY_LENGTH:
        raise ApiError(
            422, "VALIDATION_ERROR", f"Idempotency-Key must be 1-{MAX_KEY_LENGTH} characters"
        )
    # The shipment is checked synchronously so an unknown shipment is a 404, not a lost event.
    shipment = get_shipment_or_404(session, shipment_id)

    processor: EventProcessor = request.app.state.processor
    # LEGACY AP-06: 202 is returned here, before the event is persisted.
    processor.submit(
        QueuedEvent(
            shipment_id=shipment.id,
            idempotency_key=idempotency_key,
            event_type=body.event_type,
            location=body.location,
            occurred_at=body.occurred_at,
            payload=body.payload,
        )
    )
    return EventAccepted(accepted=True, idempotency_key=idempotency_key)
