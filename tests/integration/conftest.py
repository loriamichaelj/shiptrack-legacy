"""Integration fixtures: a throwaway Postgres database migrated with Alembic."""

from __future__ import annotations

import os
import uuid
from collections.abc import Callable, Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.engine import URL, make_url

from shiptrack.config import Settings
from shiptrack.main import create_app

ROOT = Path(__file__).resolve().parents[2]
ADMIN_URL = os.environ.get(
    "SHIPTRACK_TEST_DATABASE_URL", "postgresql+psycopg://postgres:postgres@localhost:5432/postgres"
)


def alembic_config() -> Config:
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "migrations"))
    return cfg


def migrate(url: URL, revision: str = "head", *, downgrade: bool = False) -> None:
    engine = create_engine(url)
    try:
        with engine.connect() as connection:
            cfg = alembic_config()
            cfg.attributes["connection"] = connection
            if downgrade:
                command.downgrade(cfg, revision)
            else:
                command.upgrade(cfg, revision)
            connection.commit()
    finally:
        engine.dispose()


def settings_for(url: URL, pod_dir: Path) -> Settings:
    return Settings(
        db_host=url.host or "localhost",
        db_port=url.port or 5432,
        db_name=url.database or "",
        db_user=url.username or "",
        db_password=url.password or "",
        db_sslmode="disable",
        pod_dir=pod_dir,
    )


@pytest.fixture(scope="session")
def admin_engine() -> Iterator[Engine]:
    engine = create_engine(ADMIN_URL, isolation_level="AUTOCOMMIT")
    yield engine
    engine.dispose()


@pytest.fixture(scope="session")
def new_database(admin_engine: Engine) -> Iterator[Callable[[], URL]]:
    """Factory for empty databases; all of them are dropped at the end of the session."""
    created: list[str] = []

    def factory() -> URL:
        name = f"shiptrack_test_{uuid.uuid4().hex[:10]}"
        with admin_engine.connect() as connection:
            connection.execute(text(f'CREATE DATABASE "{name}"'))
        created.append(name)
        return make_url(ADMIN_URL).set(database=name)

    yield factory
    with admin_engine.connect() as connection:
        for name in created:
            connection.execute(text(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)'))


@pytest.fixture(scope="session")
def database_url(new_database: Callable[[], URL]) -> URL:
    url = new_database()
    migrate(url)
    return url


@pytest.fixture(scope="session")
def engine(database_url: URL) -> Iterator[Engine]:
    engine = create_engine(database_url)
    yield engine
    engine.dispose()


@pytest.fixture(autouse=True)
def clean_tables(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(
            text(
                "TRUNCATE shiptrack.sla_alerts, shiptrack.pod_documents, "
                "shiptrack.tracking_events, shiptrack.shipments RESTART IDENTITY CASCADE"
            )
        )


@pytest.fixture()
def settings(database_url: URL, tmp_path: Path) -> Settings:
    return settings_for(database_url, tmp_path / "pod")


@pytest.fixture()
def client(settings: Settings) -> Iterator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def drain(client: TestClient) -> None:
    """Wait until the in-process event queue is empty."""
    assert client.app.state.processor.drain(timeout=10), "event queue did not drain"  # type: ignore[attr-defined]


NOW = datetime.now(UTC)


def iso(moment: datetime) -> str:
    return moment.isoformat().replace("+00:00", "Z")


@pytest.fixture()
def make_shipment(client: TestClient) -> Callable[..., dict[str, Any]]:
    def factory(
        carrier_code: str = "ACME", promised: datetime | None = None, **overrides: Any
    ) -> dict[str, Any]:
        body = {
            "carrier_code": carrier_code,
            "origin": "Rotterdam",
            "destination": "Chicago",
            "promised_delivery_at": iso(promised or NOW + timedelta(days=5)),
            **overrides,
        }
        response = client.post("/api/v1/shipments", json=body)
        assert response.status_code == 201, response.text
        return dict(response.json())

    return factory


@pytest.fixture()
def send_event(client: TestClient) -> Callable[..., Any]:
    def sender(
        shipment_id: str,
        event_type: str,
        occurred_at: datetime,
        *,
        key: str | None = None,
        location: str = "Hub",
        wait: bool = True,
    ) -> Any:
        response = client.post(
            f"/api/v1/shipments/{shipment_id}/events",
            headers={"Idempotency-Key": key or uuid.uuid4().hex},
            json={"event_type": event_type, "location": location, "occurred_at": iso(occurred_at)},
        )
        assert response.status_code == 202, response.text
        if wait:
            drain(client)
        return response

    return sender
