from collections.abc import Callable

from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import URL

from shiptrack.db.models import Base

from .conftest import migrate

TABLES = {"carriers", "shipments", "tracking_events", "pod_documents", "sla_alerts"}


def test_upgrade_from_an_empty_database(new_database: Callable[[], URL]) -> None:
    url = new_database()
    migrate(url)
    engine = create_engine(url)
    try:
        inspector = inspect(engine)
        assert set(inspector.get_table_names(schema="shiptrack")) >= TABLES
        with engine.connect() as connection:
            carriers = connection.scalars(
                text("SELECT code FROM shiptrack.carriers ORDER BY code")
            ).all()
            version = connection.scalar(text("SELECT version_num FROM shiptrack.alembic_version"))
        assert carriers == ["ACME", "BOLT", "CRWN", "MFLT", "ZZTEST"]
        assert version == "0001"
    finally:
        engine.dispose()


def test_upgrade_works_when_the_schema_already_exists(new_database: Callable[[], URL]) -> None:
    # In AWS the schema is created by db/bootstrap.sql before the first migration.
    url = new_database()
    engine = create_engine(url, isolation_level="AUTOCOMMIT")
    with engine.connect() as connection:
        connection.execute(text("CREATE SCHEMA shiptrack"))
    engine.dispose()
    migrate(url)


def test_downgrade_removes_everything(new_database: Callable[[], URL]) -> None:
    url = new_database()
    migrate(url)
    migrate(url, "base", downgrade=True)
    engine = create_engine(url)
    try:
        assert not TABLES & set(inspect(engine).get_table_names(schema="shiptrack"))
    finally:
        engine.dispose()


def test_models_match_the_migrated_schema(database_url: URL) -> None:
    engine = create_engine(database_url)
    try:
        with engine.connect() as connection:
            context = MigrationContext.configure(
                connection,
                opts={
                    "compare_type": True,
                    "compare_server_default": True,
                    "include_schemas": True,
                    "include_name": lambda name, type_, parent: (
                        parent["schema_name"] == "shiptrack"
                        if type_ == "table" and name is not None and "schema_name" in parent
                        else True
                    ),
                },
            )
            diff = [
                d
                for d in compare_metadata(context, Base.metadata)
                if "alembic_version" not in repr(d)
            ]
        assert diff == []
    finally:
        engine.dispose()


def test_sla_alerts_has_no_unique_constraint_on_shipment_id(database_url: URL) -> None:
    """AP-09: duplicates must be possible."""
    engine = create_engine(database_url)
    try:
        inspector = inspect(engine)
        uniques = inspector.get_unique_constraints("sla_alerts", schema="shiptrack")
        indexes = [
            ix for ix in inspector.get_indexes("sla_alerts", schema="shiptrack") if ix["unique"]
        ]
        assert uniques == []
        assert indexes == []
    finally:
        engine.dispose()
