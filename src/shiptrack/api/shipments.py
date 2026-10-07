"""Shipment endpoints."""

from __future__ import annotations

import secrets
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy import select, tuple_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from shiptrack.api.deps import get_shipment_or_404, to_shipment_out
from shiptrack.api.errors import ApiError
from shiptrack.api.pagination import InvalidCursorError, decode_cursor, encode_cursor
from shiptrack.db.models import Carrier, Shipment
from shiptrack.db.session import get_session
from shiptrack.domain.models import ShipmentCreate, ShipmentOut, ShipmentPage
from shiptrack.domain.status import Status

router = APIRouter(prefix="/api/v1")

TRACKING_PREFIX = "MF"
MAX_TRACKING_ATTEMPTS = 5

SessionDep = Annotated[Session, Depends(get_session)]


def generate_tracking_number() -> str:
    return f"{TRACKING_PREFIX}{secrets.randbelow(10**10):010d}"


def _carrier_by_code(session: Session, code: str) -> Carrier:
    carrier = session.scalar(select(Carrier).where(Carrier.code == code))
    if carrier is None:
        raise ApiError(422, "UNKNOWN_CARRIER", f"Unknown carrier code: {code}")
    return carrier


@router.post("/shipments", status_code=201, response_model=ShipmentOut)
def create_shipment(body: ShipmentCreate, response: Response, session: SessionDep) -> ShipmentOut:
    carrier = _carrier_by_code(session, body.carrier_code)
    for _ in range(MAX_TRACKING_ATTEMPTS):
        shipment = Shipment(
            tracking_number=generate_tracking_number(),
            carrier_id=carrier.id,
            origin=body.origin,
            destination=body.destination,
            promised_delivery_at=body.promised_delivery_at,
        )
        session.add(shipment)
        try:
            session.commit()
        except IntegrityError:
            # A collision on tracking_number: draw another number.
            session.rollback()
            continue
        session.refresh(shipment)
        response.headers["Location"] = f"/api/v1/shipments/{shipment.id}"
        return to_shipment_out(shipment)
    raise ApiError(500, "INTERNAL", "Could not allocate a tracking number")


@router.get("/shipments/{shipment_id}", response_model=ShipmentOut)
def get_shipment(shipment_id: str, session: SessionDep) -> ShipmentOut:
    return to_shipment_out(get_shipment_or_404(session, shipment_id))


@router.get("/shipments", response_model=ShipmentPage)
def list_shipments(
    session: SessionDep,
    status: Status | None = None,
    carrier_code: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    cursor: str | None = None,
) -> ShipmentPage:
    query = select(Shipment).order_by(Shipment.created_at, Shipment.id)
    if status is not None:
        query = query.where(Shipment.status == status.value)
    if carrier_code is not None:
        query = query.where(Shipment.carrier_id == _carrier_by_code(session, carrier_code).id)
    if cursor is not None:
        try:
            created_at, shipment_id = decode_cursor(cursor)
        except InvalidCursorError as exc:
            raise ApiError(422, "VALIDATION_ERROR", "Invalid cursor") from exc
        query = query.where(
            tuple_(Shipment.created_at, Shipment.id) > tuple_(created_at, shipment_id)
        )

    rows = list(session.scalars(query.limit(limit + 1)))
    page, has_more = rows[:limit], len(rows) > limit
    next_cursor = encode_cursor(page[-1].created_at, page[-1].id) if has_more else None
    return ShipmentPage(items=[to_shipment_out(s) for s in page], next_cursor=next_cursor)
