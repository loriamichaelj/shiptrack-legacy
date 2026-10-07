import logging
import threading
from collections.abc import Callable
from datetime import timedelta
from typing import Any

import pytest
from sqlalchemy import Engine, text

from shiptrack.config import Settings
from shiptrack.db.session import create_db_engine, create_session_factory
from shiptrack.jobs.sla_scan import run_scan

from .conftest import NOW

MakeShipment = Callable[..., dict[str, Any]]
SendEvent = Callable[..., Any]
PAST = NOW - timedelta(days=2)
FUTURE = NOW + timedelta(days=2)


def alerts(engine: Engine) -> list[Any]:
    with engine.connect() as connection:
        return list(
            connection.execute(
                text("SELECT shipment_id::text, detected_by FROM shiptrack.sla_alerts ORDER BY id")
            )
        )


def test_overdue_shipments_are_flagged(
    settings: Settings, engine: Engine, make_shipment: MakeShipment, send_event: SendEvent
) -> None:
    overdue = make_shipment(promised=PAST)
    make_shipment(promised=FUTURE)  # not due yet
    delivered = make_shipment(promised=PAST)
    send_event(delivered["id"], "DELIVERED", NOW - timedelta(days=3))

    factory = create_session_factory(create_db_engine(settings))
    assert run_scan(factory, "host-a") == 1

    assert alerts(engine) == [(overdue["id"], "host-a")]
    with engine.connect() as connection:
        row = connection.execute(
            text("SELECT sla_breached, sla_breached_at FROM shiptrack.shipments WHERE id = :id"),
            {"id": overdue["id"]},
        ).one()
    assert row.sla_breached is True
    assert row.sla_breached_at is not None


def test_a_flagged_shipment_is_not_alerted_again(
    settings: Settings, engine: Engine, make_shipment: MakeShipment
) -> None:
    make_shipment(promised=PAST)
    factory = create_session_factory(create_db_engine(settings))
    assert run_scan(factory, "host-a") == 1
    assert run_scan(factory, "host-a") == 0
    assert len(alerts(engine)) == 1


def test_breaches_are_logged(
    settings: Settings, make_shipment: MakeShipment, caplog: pytest.LogCaptureFixture
) -> None:
    shipment = make_shipment(promised=PAST)
    factory = create_session_factory(create_db_engine(settings))
    with caplog.at_level(logging.INFO, logger="shiptrack.sla"):
        run_scan(factory, "host-a")
    message = next(r.message for r in caplog.records if r.message.startswith("SLA_BREACH"))
    assert f"tracking={shipment['tracking_number']}" in message
    assert "host=host-a" in message
    assert "promised=" in message


def test_two_scanners_raise_duplicate_alerts(
    settings: Settings, engine: Engine, make_shipment: MakeShipment
) -> None:
    """AP-09: with cron on both hosts and no locking, the same breach is alerted twice."""
    shipment = make_shipment(promised=PAST)
    factory = create_session_factory(create_db_engine(settings))
    barrier = threading.Barrier(2, timeout=10)  # both scanners read before either writes

    results: dict[str, int] = {}

    def scan(host: str) -> None:
        results[host] = run_scan(factory, host, between_read_and_write=barrier.wait)

    threads = [threading.Thread(target=scan, args=(h,)) for h in ("host-a", "host-b")]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=20)

    assert results == {"host-a": 1, "host-b": 1}
    rows = alerts(engine)
    assert len(rows) == 2
    assert {r[0] for r in rows} == {shipment["id"]}
    assert {r[1] for r in rows} == {"host-a", "host-b"}
    with engine.connect() as connection:
        duplicates = connection.scalar(
            text(
                "SELECT count(*) FROM (SELECT shipment_id FROM shiptrack.sla_alerts "
                "GROUP BY 1 HAVING count(*) > 1) d"
            )
        )
    assert duplicates == 1
