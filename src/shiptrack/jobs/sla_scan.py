"""SLA breach scan, run from cron on every host.

# LEGACY AP-09: cron runs on both instances and this scan is a naive read-then-write with no
# locking, so two scanners that read before either writes both raise an alert for the same
# shipment.
"""

from __future__ import annotations

import dataclasses
import logging
import socket
from collections.abc import Callable

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, sessionmaker

from shiptrack.config import configure_logging, load_settings
from shiptrack.db.models import Shipment, SlaAlert
from shiptrack.db.session import create_db_engine, create_session_factory
from shiptrack.domain.models import format_utc
from shiptrack.domain.status import Status

logger = logging.getLogger("shiptrack.sla")


def run_scan(
    session_factory: sessionmaker[Session],
    hostname: str,
    between_read_and_write: Callable[[], None] | None = None,
) -> int:
    """Alert on every undelivered, overdue, not-yet-flagged shipment; return how many.

    `between_read_and_write` is a test hook that lets a test hold two scanners between the
    read and the write so the AP-09 race is deterministic.
    """
    with session_factory() as session:
        overdue = session.execute(
            select(Shipment.id, Shipment.tracking_number, Shipment.promised_delivery_at).where(
                Shipment.status != Status.DELIVERED.value,
                Shipment.promised_delivery_at < func.now(),
                Shipment.sla_breached.is_(False),
            )
        ).all()
        if between_read_and_write is not None:
            between_read_and_write()
        for shipment_id, tracking_number, promised in overdue:
            session.add(SlaAlert(shipment_id=shipment_id, detected_by=hostname))
            session.execute(
                update(Shipment)
                .where(Shipment.id == shipment_id)
                .values(sla_breached=True, sla_breached_at=func.now(), updated_at=func.now())
            )
            logger.info(
                "SLA_BREACH tracking=%s promised=%s host=%s",
                tracking_number,
                format_utc(promised),
                hostname,
            )
        session.commit()
    return len(overdue)


def main() -> None:
    # Cron redirects stdout/stderr to sla.log, so log to the console only.
    settings = dataclasses.replace(load_settings(), log_file=None)
    configure_logging(settings)
    engine = create_db_engine(settings)
    try:
        count = run_scan(create_session_factory(engine), socket.gethostname())
        logger.info("sla scan finished breaches=%d", count)
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
