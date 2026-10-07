"""Health check."""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import PlainTextResponse

router = APIRouter()


@router.get("/", response_class=PlainTextResponse)
def health() -> str:
    # LEGACY AP-07: shallow health check; answers OK without touching the database, so the
    # ALB keeps a host in rotation while the API behind it returns 500s.
    return "OK"
