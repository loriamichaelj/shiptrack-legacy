"""Engine and session helpers."""

from __future__ import annotations

from collections.abc import Iterator

from fastapi import Request
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session, sessionmaker

from shiptrack.config import Settings


def create_db_engine(settings: Settings) -> Engine:
    # SQLAlchemy's default pool (5 + 10 overflow) is deliberate: the connection budget in
    # the modern design counts 15 connections per gunicorn worker.
    return create_engine(settings.database_url, pool_pre_ping=True)


def create_session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine, expire_on_commit=False)


def get_session(request: Request) -> Iterator[Session]:
    factory: sessionmaker[Session] = request.app.state.session_factory
    with factory() as session:
        yield session
