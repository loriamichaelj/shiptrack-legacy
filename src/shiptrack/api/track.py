"""Public tracking view."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from shiptrack.api.errors import not_found
from shiptrack.db.models import Shipment, TrackingEvent
from shiptrack.db.session import get_session
from shiptrack.domain.models import TrackEvent, TrackView
from shiptrack.domain.status import Status

router = APIRouter(prefix="/api/v1")


@router.get("/track/{tracking_number}", response_model=TrackView)
def track(tracking_number: str, session: Annotated[Session, Depends(get_session)]) -> TrackView:
    shipment = session.scalar(select(Shipment).where(Shipment.tracking_number == tracking_number))
    if shipment is None:
        raise not_found("Shipment not found")
    events = session.scalars(
        select(TrackingEvent)
        .where(TrackingEvent.shipment_id == shipment.id, TrackingEvent.applied.is_(True))
        .order_by(TrackingEvent.occurred_at, TrackingEvent.id)
    )
    return TrackView(
        tracking_number=shipment.tracking_number,
        carrier_code=shipment.carrier.code,
        status=Status(shipment.status),
        estimated_delivery_at=shipment.estimated_delivery_at,
        delivered_at=shipment.delivered_at,
        events=[
            TrackEvent(
                event_type=Status(e.event_type), location=e.location, occurred_at=e.occurred_at
            )
            for e in events
        ],
    )
