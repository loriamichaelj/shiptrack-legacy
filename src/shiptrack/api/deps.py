"""Shared helpers for route modules."""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from shiptrack.api.errors import not_found
from shiptrack.db.models import Shipment
from shiptrack.domain.models import ShipmentOut
from shiptrack.domain.status import Status


def parse_uuid(value: str, what: str = "Shipment") -> uuid.UUID:
    """Parse a path UUID; a malformed ID is simply a resource that does not exist."""
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise not_found(f"{what} not found") from exc


def get_shipment_or_404(session: Session, shipment_id: str) -> Shipment:
    shipment = session.scalar(select(Shipment).where(Shipment.id == parse_uuid(shipment_id)))
    if shipment is None:
        raise not_found("Shipment not found")
    return shipment


def to_shipment_out(shipment: Shipment) -> ShipmentOut:
    return ShipmentOut(
        id=shipment.id,
        tracking_number=shipment.tracking_number,
        carrier_code=shipment.carrier.code,
        origin=shipment.origin,
        destination=shipment.destination,
        status=Status(shipment.status),
        promised_delivery_at=shipment.promised_delivery_at,
        estimated_delivery_at=shipment.estimated_delivery_at,
        delivered_at=shipment.delivered_at,
        sla_breached=shipment.sla_breached,
        created_at=shipment.created_at,
        updated_at=shipment.updated_at,
    )
