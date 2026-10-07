"""FastAPI application factory."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from shiptrack import __version__
from shiptrack.api import events, health, pod, shipments, track
from shiptrack.api.errors import register_exception_handlers
from shiptrack.config import Settings, configure_logging, load_settings
from shiptrack.db.session import create_db_engine, create_session_factory
from shiptrack.events.processor import EventProcessor


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the app. Settings are loaded at startup (not import) unless passed in."""

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        resolved = settings or load_settings()
        configure_logging(resolved)
        engine = create_db_engine(resolved)
        session_factory = create_session_factory(engine)
        processor = EventProcessor(session_factory)
        app.state.settings = resolved
        app.state.session_factory = session_factory
        app.state.processor = processor
        processor.start()
        try:
            yield
        finally:
            # Queued events that have not been applied are dropped here (LEGACY AP-06).
            processor.stop()
            engine.dispose()

    app = FastAPI(
        title="ShipTrack",
        version=__version__,
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    register_exception_handlers(app)
    app.include_router(health.router)
    app.include_router(shipments.router)
    app.include_router(events.router)
    app.include_router(track.router)
    app.include_router(pod.router)
    return app


app = create_app()
