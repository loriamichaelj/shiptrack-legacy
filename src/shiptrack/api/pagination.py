"""Opaque keyset cursors over (created_at, id)."""

from __future__ import annotations

import base64
import binascii
import json
import uuid
from datetime import datetime


class InvalidCursorError(ValueError):
    pass


def encode_cursor(created_at: datetime, shipment_id: uuid.UUID) -> str:
    raw = json.dumps({"c": created_at.isoformat(), "i": str(shipment_id)}, separators=(",", ":"))
    return base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        data = json.loads(base64.urlsafe_b64decode(padded.encode()))
        created_at = datetime.fromisoformat(data["c"])
        if created_at.tzinfo is None:
            raise InvalidCursorError("cursor timestamp is not timezone-aware")
        return created_at, uuid.UUID(data["i"])
    except (binascii.Error, ValueError, KeyError, TypeError) as exc:
        raise InvalidCursorError("invalid cursor") from exc
