"""scripts/reset_data.py: delete everything, keep carriers, seed five, refuse without a go-ahead."""

import datetime as dt
import importlib.util
import textwrap
import uuid
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text
from sqlalchemy.engine import URL
from sqlalchemy.orm import Session

MakeShipment = Callable[..., dict[str, Any]]
SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "reset_data.py"


def load_job() -> ModuleType:
    spec = importlib.util.spec_from_file_location("reset_data", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def counts(engine: Engine) -> dict[str, int]:
    with engine.connect() as connection:
        return {
            table: int(
                connection.execute(text(f"SELECT count(*) FROM shiptrack.{table}")).scalar_one()
            )
            for table in ("shipments", "tracking_events", "pod_documents", "sla_alerts", "carriers")
        }


def fill(engine: Engine, make_shipment: MakeShipment) -> None:
    """Shipments with an event, a document, and an alert each."""
    for n in range(3):
        sid = make_shipment()["id"]
        with engine.begin() as connection:
            connection.execute(
                text(
                    "INSERT INTO shiptrack.tracking_events "
                    "(shipment_id, event_type, location, occurred_at, idempotency_key, applied) "
                    "VALUES (:sid, 'PICKED_UP', 'Hub', now(), :key, true)"
                ),
                {"sid": sid, "key": f"fill-{uuid.uuid4()}-{n}"},
            )
            connection.execute(
                text(
                    "INSERT INTO shiptrack.pod_documents "
                    "(id, shipment_id, storage_uri, content_type, size_bytes, sha256) "
                    "VALUES (:id, :sid, 's3://b/pod/x', 'image/png', 1, :sha)"
                ),
                {"id": str(uuid.uuid4()), "sid": sid, "sha": "0" * 64},
            )
            connection.execute(
                text(
                    "INSERT INTO shiptrack.sla_alerts (shipment_id, detected_by) VALUES (:sid, 'h')"
                ),
                {"sid": sid},
            )


def run(engine: Engine, *, seed: bool) -> dict[str, int]:
    job = load_job()
    with Session(engine) as session, session.begin():
        deleted: dict[str, int] = job.delete_everything(session)
        if seed:
            job.seed(session, dt.datetime.now(dt.UTC))
    return deleted


def test_it_deletes_everything_and_keeps_the_carriers(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    fill(engine, make_shipment)
    before = counts(engine)
    assert before["shipments"] == 3 and before["tracking_events"] == 3
    assert before["pod_documents"] == 3 and before["sla_alerts"] == 3

    deleted = run(engine, seed=False)

    after = counts(engine)
    assert deleted == {"sla_alerts": 3, "pod_documents": 3, "tracking_events": 3, "shipments": 3}
    assert (
        after["shipments"],
        after["tracking_events"],
        after["pod_documents"],
        after["sla_alerts"],
    ) == (0, 0, 0, 0)
    assert after["carriers"] == before["carriers"] > 0


def test_it_seeds_five_shipments_that_the_api_can_track(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    fill(engine, make_shipment)
    run(engine, seed=True)

    assert counts(engine)["shipments"] == 5
    expected = {
        "MF0000000001": "CREATED",
        "MF0000000002": "PICKED_UP",
        "MF0000000003": "IN_TRANSIT",
        "MF0000000004": "OUT_FOR_DELIVERY",
        "MF0000000005": "DELIVERED",
    }
    for number, status in expected.items():
        response = client.get(f"/api/v1/track/{number}")
        assert response.status_code == 200, number
        body = response.json()
        assert body["status"] == status
        assert len(body["events"]) == [
            "CREATED",
            "PICKED_UP",
            "IN_TRANSIT",
            "OUT_FOR_DELIVERY",
            "DELIVERED",
        ].index(status)
    assert client.get("/api/v1/track/MF0000000005").json()["delivered_at"] is not None


def test_running_it_twice_leaves_the_same_five(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    run(engine, seed=True)
    again = run(engine, seed=True)
    assert again["shipments"] == 5
    assert counts(engine)["shipments"] == 5


def test_the_job_seeds_only_the_missing_ones(client: TestClient, engine: Engine) -> None:
    job = load_job()
    with Session(engine) as session, session.begin():
        job.seed(session, dt.datetime.now(dt.UTC))
        # a second seed without a delete adds nothing: the numbers are fixed and unique
        job.seed(session, dt.datetime.now(dt.UTC))
    assert counts(engine)["shipments"] == 5


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


def test_the_command_line_refuses_without_the_exact_confirmation(
    client: TestClient,
    make_shipment: MakeShipment,
    engine: Engine,
    config_file: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    make_shipment()
    job = load_job()
    assert job.main(["--confirm", "yes please"]) == 2
    assert "refused" in capsys.readouterr().err
    assert counts(engine)["shipments"] == 1


def test_the_command_line_prints_numbers_and_the_seeded_tracking_numbers(
    client: TestClient,
    make_shipment: MakeShipment,
    engine: Engine,
    config_file: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    make_shipment()
    make_shipment()
    job = load_job()

    assert job.main(["--confirm", "delete-all-shipments", "--seed", "yes"]) == 0
    out = capsys.readouterr().out.splitlines()
    assert out[0] == "RESET_DATA deleted shipments=2 tracking_events=0 pod_documents=0 sla_alerts=0"
    assert out[1].startswith("RESET_DATA now shipments=5 carriers=")
    assert out[2] == "SEEDED MF0000000001 MF0000000002 MF0000000003 MF0000000004 MF0000000005"
    assert counts(engine)["shipments"] == 5

    assert job.main(["--confirm", "delete-all-shipments", "--seed", "no"]) == 0
    assert "SEEDED" not in capsys.readouterr().out
    assert counts(engine)["shipments"] == 0
