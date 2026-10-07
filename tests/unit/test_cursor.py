import base64
import json
import uuid
from datetime import UTC, datetime

import pytest

from shiptrack.api.pagination import InvalidCursorError, decode_cursor, encode_cursor


def test_round_trip() -> None:
    created = datetime(2026, 10, 1, 12, 30, 45, 123456, tzinfo=UTC)
    shipment_id = uuid.uuid4()
    assert decode_cursor(encode_cursor(created, shipment_id)) == (created, shipment_id)


def test_cursor_is_opaque_url_safe_text() -> None:
    cursor = encode_cursor(datetime(2026, 10, 1, tzinfo=UTC), uuid.uuid4())
    assert "=" not in cursor
    assert all(c.isalnum() or c in "-_" for c in cursor)


def _b64(data: object) -> str:
    return base64.urlsafe_b64encode(json.dumps(data).encode()).decode()


@pytest.mark.parametrize(
    "cursor",
    [
        "",
        "not-base64!!",
        base64.urlsafe_b64encode(b"not json").decode(),
        _b64({"c": "2026-10-01T00:00:00+00:00"}),
        _b64({"c": "yesterday", "i": str(uuid.uuid4())}),
        _b64({"c": "2026-10-01T00:00:00", "i": str(uuid.uuid4())}),
        _b64({"c": "2026-10-01T00:00:00+00:00", "i": "not-a-uuid"}),
        _b64([1, 2, 3]),
    ],
)
def test_invalid_cursors_are_rejected(cursor: str) -> None:
    with pytest.raises(InvalidCursorError):
        decode_cursor(cursor)
