"""The read-only evidence checks that run on a host through ShipTrack-Evidence."""

import sys
import textwrap
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text
from sqlalchemy.engine import URL
from sqlalchemy.orm import Session

from shiptrack.jobs import evidence

MakeShipment = Callable[..., dict[str, Any]]


def add_document(engine: Engine, shipment_id: str, uri: str, *, minutes_old: int) -> None:
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO shiptrack.pod_documents "
                "(id, shipment_id, storage_uri, content_type, size_bytes, sha256, uploaded_at) "
                "VALUES (:id, :sid, :uri, 'image/png', 1, :sha, now() - make_interval(mins => :m))"
            ),
            {
                "id": str(uuid.uuid4()),
                "sid": shipment_id,
                "uri": uri,
                "sha": "0" * 64,
                "m": minutes_old,
            },
        )


def add_alert(engine: Engine, shipment_id: str) -> None:
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO shiptrack.sla_alerts (shipment_id, detected_by) VALUES (:sid, 'host')"
            ),
            {"sid": shipment_id},
        )


def test_pod_gate_counts_only_old_local_documents(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    sid = make_shipment()["id"]
    add_document(engine, sid, "file:///var/lib/shiptrack/pod/a/old", minutes_old=10)
    add_document(engine, sid, "file:///var/lib/shiptrack/pod/a/older", minutes_old=60)
    add_document(engine, sid, "file:///var/lib/shiptrack/pod/a/fresh", minutes_old=1)
    add_document(engine, sid, "s3://bucket/pod/a/moved", minutes_old=120)

    with Session(engine) as session:
        assert evidence.pod_gate(session) == 2


def test_pod_gate_is_zero_once_everything_old_is_in_s3(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    sid = make_shipment()["id"]
    add_document(engine, sid, "s3://bucket/pod/a/moved", minutes_old=120)
    add_document(engine, sid, "file:///var/lib/shiptrack/pod/a/fresh", minutes_old=2)

    with Session(engine) as session:
        assert evidence.pod_gate(session) == 0


def test_sla_duplicates_counts_shipments_and_extra_alerts(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    twice, thrice, once = (make_shipment()["id"] for _ in range(3))
    for sid, times in ((twice, 2), (thrice, 3), (once, 1)):
        for _ in range(times):
            add_alert(engine, sid)

    with Session(engine) as session:
        assert evidence.sla_duplicates(session) == (2, 3)


def test_no_alerts_is_zero_and_zero(client: TestClient, engine: Engine) -> None:
    with Session(engine) as session:
        assert evidence.sla_duplicates(session) == (0, 0)
        assert evidence.sla_alert_total(session) == 0


def test_the_alert_total_counts_every_alert(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    twice, once = (make_shipment()["id"] for _ in range(2))
    for sid, times in ((twice, 2), (once, 1)):
        for _ in range(times):
            add_alert(engine, sid)

    with Session(engine) as session:
        assert evidence.sla_alert_total(session) == 3


@pytest.fixture()
def config_file(database_url: URL, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    path = tmp_path / "app.ini"
    path.write_text(
        textwrap.dedent(
            f"""
            [database]
            host = {database_url.host}
            port = {database_url.port}
            name = {database_url.database}
            user = {database_url.username}
            password = {database_url.password}
            sslmode = disable
            """
        )
    )
    monkeypatch.setenv("SHIPTRACK_CONFIG", str(path))
    return path


def test_cli_prints_one_line_of_numbers_and_exits_nonzero_when_the_gate_fails(
    client: TestClient,
    make_shipment: MakeShipment,
    engine: Engine,
    config_file: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    sid = make_shipment()["id"]
    add_document(engine, sid, "file:///var/lib/shiptrack/pod/a/old", minutes_old=30)

    code = evidence.main(["pod-gate"])

    out = capsys.readouterr().out
    assert code == 1
    assert out == "POD_GATE file_uris_older_than_5_minutes=1\n"


def test_cli_pod_gate_passes_at_zero(
    client: TestClient, config_file: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert evidence.main(["pod-gate"]) == 0
    assert capsys.readouterr().out == "POD_GATE file_uris_older_than_5_minutes=0\n"


def test_cli_sla_duplicates_is_evidence_not_a_gate(
    client: TestClient,
    make_shipment: MakeShipment,
    engine: Engine,
    config_file: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    sid = make_shipment()["id"]
    add_alert(engine, sid)
    add_alert(engine, sid)

    assert evidence.main(["sla-duplicates"]) == 0
    assert capsys.readouterr().out == "SLA_DUPLICATES shipments=1 extra_alerts=1 alerts=2\n"


def simulator_stub(root: Path, *, accepted: int, persisted: int, missing: int) -> Path:
    """A stand-in for the platform's simulator package, with the same verify_ledger shape."""
    # A real run is a fresh process; here the module may already be cached by an earlier stub.
    for name in [m for m in sys.modules if m.startswith("shiptrack_simulator")]:
        del sys.modules[name]
    package = root / "shiptrack_simulator"
    package.mkdir(parents=True)
    (package / "__init__.py").write_text("")
    (package / "verify.py").write_text(
        textwrap.dedent(
            f"""
            from types import SimpleNamespace

            def verify_ledger(ledger_path, db_url):
                assert str(db_url).startswith("postgresql://")
                return SimpleNamespace(
                    accepted={accepted}, persisted={persisted}, missing=[0] * {missing}
                )
            """
        )
    )
    return root


def test_ledger_verify_reports_counts_only_and_fails_on_a_lost_event(
    client: TestClient,
    config_file: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    ledger = tmp_path / "ledger.jsonl"
    ledger.write_text("")
    simulator = simulator_stub(tmp_path / "sim", accepted=100, persisted=98, missing=2)

    code = evidence.main(["ledger-verify", "--ledger", str(ledger), "--simulator", str(simulator)])

    assert code == 1
    assert capsys.readouterr().out == "LEDGER_VERIFY accepted=100 persisted=98 missing=2\n"


def test_ledger_verify_passes_when_nothing_is_missing(
    client: TestClient,
    config_file: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    ledger = tmp_path / "ledger.jsonl"
    ledger.write_text("")
    simulator = simulator_stub(tmp_path / "sim2", accepted=50, persisted=50, missing=0)

    code = evidence.main(["ledger-verify", "--ledger", str(ledger), "--simulator", str(simulator)])

    assert code == 0
    assert capsys.readouterr().out == "LEDGER_VERIFY accepted=50 persisted=50 missing=0\n"
