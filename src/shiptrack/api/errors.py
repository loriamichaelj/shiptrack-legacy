"""Error envelope and exception handlers.

Every 4xx/5xx response, including validation errors, uses:
    {"error": {"code": "...", "message": "...", "request_id": null}}
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger(__name__)

_STATUS_CODES = {404: "NOT_FOUND", 422: "VALIDATION_ERROR"}


class ApiError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def not_found(message: str = "Not found") -> ApiError:
    return ApiError(404, "NOT_FOUND", message)


def _envelope(status_code: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"error": {"code": code, "message": message, "request_id": None}},
    )


def _validation_message(exc: RequestValidationError) -> str:
    parts = []
    for err in exc.errors():
        location = ".".join(str(part) for part in err["loc"] if part != "body")
        parts.append(f"{location}: {err['msg']}" if location else str(err["msg"]))
    return "; ".join(parts) or "Invalid request"


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        return _envelope(exc.status_code, exc.code, exc.message)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        return _envelope(422, "VALIDATION_ERROR", _validation_message(exc))

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        fallback = "INTERNAL" if exc.status_code >= 500 else "VALIDATION_ERROR"
        code = _STATUS_CODES.get(exc.status_code, fallback)
        return _envelope(exc.status_code, code, str(exc.detail))

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception) -> JSONResponse:
        logger.exception("unhandled error", exc_info=exc)
        return _envelope(500, "INTERNAL", "Internal server error")
