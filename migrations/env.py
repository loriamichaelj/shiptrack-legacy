"""Alembic environment.

Connection resolution, in order:
1. a connection passed in by the caller (`config.attributes["connection"]`), used by tests;
2. the database from the INI config (`shiptrack.config.load_settings`), used on the hosts.
"""

from __future__ import annotations

from alembic import context
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Connection

from shiptrack.config import load_settings
from shiptrack.db.models import SCHEMA, Base

config = context.config
target_metadata = Base.metadata


def _ensure_schema(connection: Connection) -> None:
    # The schema is normally created by db/bootstrap.sql and owned by the migrator role, which
    # may not hold CREATE on the database, so only create it when it is missing.
    exists = connection.scalar(
        text("SELECT 1 FROM information_schema.schemata WHERE schema_name = :name"),
        {"name": SCHEMA},
    )
    if not exists:
        connection.execute(text(f'CREATE SCHEMA "{SCHEMA}"'))
    connection.commit()


def _run(connection: Connection) -> None:
    _ensure_schema(connection)
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        version_table_schema=SCHEMA,
        include_schemas=False,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connection = config.attributes.get("connection")
    if connection is not None:
        _run(connection)
        return
    engine = create_engine(load_settings().database_url)
    try:
        with engine.connect() as conn:
            _run(conn)
    finally:
        engine.dispose()


run_migrations_online()
