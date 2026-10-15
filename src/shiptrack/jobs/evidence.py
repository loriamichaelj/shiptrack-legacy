"""Read-only evidence checks, run on a legacy host through the ShipTrack-Evidence SSM document.

GitHub-hosted runners cannot reach the private database, so the queries that prove an anti-pattern
or gate a cutover step run here, on a host that can. Each check prints one line of numbers and
nothing else: no row, key, tracking number, or address reaches a log of a public repository.

    POD_GATE file_uris_older_than_5_minutes=<n>          exit 1 when n > 0   (cutover gate G-POD)
    SLA_DUPLICATES shipments=<n> extra_alerts=<m> alerts=<t>   exit 0       (AP-09 evidence)
    LEDGER_VERIFY accepted=<a> persisted=<p> missing=<m> exit 1 when m > 0   (AP-06 and wave 2)
"""

from __future__ import annotations

import argparse
import dataclasses
import logging
import sys
from collections.abc import Sequence
from pathlib import Path

from sqlalchemy import func, select, text
from sqlalchemy.engine import URL
from sqlalchemy.orm import Session

from shiptrack.config import Settings, load_settings
from shiptrack.db.models import ProofOfDeliveryDocument, SlaAlert
from shiptrack.db.session import create_db_engine, create_session_factory

logger = logging.getLogger("shiptrack.evidence")

PROOF_OF_DELIVERY_GATE_MINUTES = 5


def proof_of_delivery_gate(session: Session) -> int:
    """Documents still stored as file:// that were uploaded more than five minutes ago.

    Modern reads proof of delivery from S3 only, so any such document is unreadable through it
    beyond the accepted proof-of-delivery sync window. The cutover step may proceed only at zero.
    """
    count = session.scalar(
        select(func.count())
        .select_from(ProofOfDeliveryDocument)
        .where(
            ProofOfDeliveryDocument.storage_uri.like("file://%"),
            ProofOfDeliveryDocument.uploaded_at
            < func.now() - text(f"interval '{PROOF_OF_DELIVERY_GATE_MINUTES} minutes'"),
        )
    )
    return int(count or 0)


def sla_duplicates(session: Session) -> tuple[int, int]:
    """(shipments with more than one SLA alert, alerts beyond the first), the AP-09 evidence."""
    per_shipment = (
        select(SlaAlert.shipment_id, func.count().label("alerts"))
        .group_by(SlaAlert.shipment_id)
        .having(func.count() > 1)
        .subquery()
    )
    shipments, extra = session.execute(
        select(func.count(), func.coalesce(func.sum(per_shipment.c.alerts - 1), 0)).select_from(
            per_shipment
        )
    ).one()
    return int(shipments), int(extra)


def sla_alert_total(session: Session) -> int:
    """All SLA alerts: with the duplicates, it shows that scans raised breaches once each."""
    return int(session.scalar(select(func.count()).select_from(SlaAlert)) or 0)


def psycopg_url(settings: Settings) -> str:
    """The connection URL psycopg itself takes, built in memory and never printed or logged."""
    url = URL.create(
        "postgresql",
        username=settings.db_user,
        password=settings.db_password,
        host=settings.db_host,
        port=settings.db_port,
        database=settings.db_name,
        query={"sslmode": settings.db_sslmode},
    )
    return url.render_as_string(hide_password=False)


def ledger_verify(ledger: Path, simulator_path: Path, settings: Settings) -> tuple[int, int, int]:
    """(accepted, persisted, missing) for a simulator ledger, using the simulator's own verify."""
    sys.path.insert(0, str(simulator_path))
    from shiptrack_simulator.verify import verify_ledger  # noqa: PLC0415

    result = verify_ledger(ledger, psycopg_url(settings))
    return result.accepted, result.persisted, len(result.missing)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only evidence checks.")
    commands = parser.add_subparsers(dest="check", required=True)
    commands.add_parser("pod-gate", help="file:// documents older than five minutes (G-POD)")
    commands.add_parser("sla-duplicates", help="duplicate SLA alerts (AP-09)")
    verify = commands.add_parser("ledger-verify", help="events in a simulator ledger not persisted")
    verify.add_argument("--ledger", type=Path, required=True)
    verify.add_argument(
        "--simulator", type=Path, required=True, help="directory holding the simulator package"
    )
    args = parser.parse_args(argv)

    settings = dataclasses.replace(load_settings(), log_file=None)
    logging.basicConfig(level=logging.WARNING)

    if args.check == "ledger-verify":
        accepted, persisted, missing = ledger_verify(args.ledger, args.simulator, settings)
        print(f"LEDGER_VERIFY accepted={accepted} persisted={persisted} missing={missing}")
        return 1 if missing else 0

    engine = create_db_engine(settings)
    try:
        with create_session_factory(engine)() as session:
            if args.check == "pod-gate":
                count = proof_of_delivery_gate(session)
                minutes = PROOF_OF_DELIVERY_GATE_MINUTES
                print(f"POD_GATE file_uris_older_than_{minutes}_minutes={count}")
                return 1 if count else 0
            shipments, extra = sla_duplicates(session)
            print(
                f"SLA_DUPLICATES shipments={shipments} extra_alerts={extra} "
                f"alerts={sla_alert_total(session)}"
            )
            return 0
    finally:
        engine.dispose()


if __name__ == "__main__":
    sys.exit(main())
