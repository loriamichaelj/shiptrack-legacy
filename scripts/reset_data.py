"""Delete every shipment and what hangs off it, then optionally seed five demo shipments.

Run on a legacy host by ShipTrack-ResetData, with the release's virtualenv and the credentials in
/etc/shiptrack/app.ini, because the database is private. It is the only place that deletes
shipments: the API has no delete, and the contract is frozen.

What is deleted: sla_alerts, pod_documents, tracking_events, shipments, in that order, in one
transaction. What is kept: carriers (reference data) and the schema.

The seeded shipments have fixed tracking numbers so that they can be looked up by hand:

    MF0000000001 Created, MF0000000002 Picked up, MF0000000003 In transit,
    MF0000000004 Out for delivery, MF0000000005 Delivered

Output is lines of numbers and these tracking numbers, which are synthetic:

    RESET_DATA deleted shipments=<n> tracking_events=<n> pod_documents=<n> sla_alerts=<n>
    RESET_DATA now shipments=<n> carriers=<n>
    SEEDED MF0000000001 MF0000000002 ...
"""

from __future__ import annotations

import argparse
import dataclasses
import logging
import sys
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from shiptrack.config import load_settings
from shiptrack.db.models import Carrier, PodDocument, Shipment, SlaAlert, TrackingEvent
from shiptrack.db.session import create_db_engine, create_session_factory

CONFIRM = "delete-all-shipments"
CARRIER = "ACME"

FULL_PATH = ("PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY", "DELIVERED")

# (tracking number, origin, destination, the events it has had, oldest first)
SEEDS: list[tuple[str, str, str, list[str]]] = [
    ("MF0000000001", "Rotterdam", "Hamburg", []),
    ("MF0000000002", "Leeds", "Cardiff", ["PICKED_UP"]),
    ("MF0000000003", "Lyon", "Gdansk", ["PICKED_UP", "IN_TRANSIT"]),
    ("MF0000000004", "Bilbao", "Antwerp", ["PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY"]),
    (
        "MF0000000005",
        "Hamburg",
        "Leeds",
        ["PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY", "DELIVERED"],
    ),
]
LOCATIONS = {
    "PICKED_UP": "Origin depot",
    "IN_TRANSIT": "Sorting hub",
    "OUT_FOR_DELIVERY": "Local depot",
    "DELIVERED": "Destination",
}


def _count(session: Session, model: type) -> int:
    return int(session.scalar(select(func.count()).select_from(model)) or 0)


def delete_everything(session: Session) -> dict[str, int]:
    """Delete in foreign-key order. The caller commits."""
    deleted = {
        "sla_alerts": _count(session, SlaAlert),
        "pod_documents": _count(session, PodDocument),
        "tracking_events": _count(session, TrackingEvent),
        "shipments": _count(session, Shipment),
    }
    for model in (SlaAlert, PodDocument, TrackingEvent, Shipment):
        session.execute(delete(model))
    return deleted


def seed(session: Session, now: datetime) -> list[str]:
    """Create the demo shipments that are not there. Returns the tracking numbers."""
    carrier = session.scalar(select(Carrier).where(Carrier.code == CARRIER))
    if carrier is None:
        carrier = session.scalars(select(Carrier).order_by(Carrier.id)).first()
    if carrier is None:
        raise SystemExit("there is no carrier to seed shipments with")
    numbers: list[str] = []
    for index, (number, origin, destination, events) in enumerate(SEEDS):
        numbers.append(number)
        if (
            session.scalar(select(Shipment.id).where(Shipment.tracking_number == number))
            is not None
        ):
            continue
        created = now - timedelta(hours=30 - index)
        promised = now + timedelta(days=2)
        status = events[-1] if events else "CREATED"
        last = created + timedelta(hours=3 * len(events)) if events else None
        shipment = Shipment(
            tracking_number=number,
            carrier_id=carrier.id,
            origin=origin,
            destination=destination,
            status=status,
            promised_delivery_at=promised,
            estimated_delivery_at=promised - timedelta(hours=3) if events else None,
            delivered_at=last if status == "DELIVERED" else None,
            last_event_at=last,
            created_at=created,
            updated_at=last or created,
        )
        session.add(shipment)
        session.flush()
        for step, kind in enumerate(events, start=1):
            session.add(
                TrackingEvent(
                    shipment_id=shipment.id,
                    event_type=kind,
                    location=LOCATIONS[kind],
                    occurred_at=created + timedelta(hours=3 * step),
                    idempotency_key=f"seed-{number}-{kind}",
                    applied=True,
                )
            )
    return numbers


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Delete all shipments, optionally seed five.")
    parser.add_argument("--confirm", required=True, help=f"must be {CONFIRM}")
    parser.add_argument("--seed", choices=["yes", "no"], default="yes")
    args = parser.parse_args(argv)
    if args.confirm != CONFIRM:
        print(f"refused: --confirm must be {CONFIRM}", file=sys.stderr)
        return 2

    logging.basicConfig(level=logging.WARNING)
    settings = dataclasses.replace(load_settings(), log_file=None)
    engine = create_db_engine(settings)
    try:
        with create_session_factory(engine)() as session:
            with session.begin():
                deleted = delete_everything(session)
                numbers = seed(session, datetime.now(UTC)) if args.seed == "yes" else []
            shipments = _count(session, Shipment)
            carriers = _count(session, Carrier)
    finally:
        engine.dispose()

    print(
        "RESET_DATA deleted "
        f"shipments={deleted['shipments']} tracking_events={deleted['tracking_events']} "
        f"pod_documents={deleted['pod_documents']} sla_alerts={deleted['sla_alerts']}"
    )
    print(f"RESET_DATA now shipments={shipments} carriers={carriers}")
    if numbers:
        print("SEEDED " + " ".join(numbers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
