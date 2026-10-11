"""An in-memory stand-in for the two S3 calls the application makes.

It raises real botocore ClientError objects and verifies the SHA-256 checksum on upload the way S3
does, so the tests exercise the same error paths as production without a server or a new
dependency.
"""

from __future__ import annotations

import base64
import hashlib
from collections.abc import Iterator
from typing import Any

from botocore.exceptions import ClientError


class FakeBody:
    def __init__(self, data: bytes) -> None:
        self._data = data
        self.closed = False

    def iter_chunks(self, chunk_size: int = 1024) -> Iterator[bytes]:
        for start in range(0, len(self._data), chunk_size):
            yield self._data[start : start + chunk_size]

    def read(self) -> bytes:
        return self._data

    def close(self) -> None:
        self.closed = True


class FakeS3:
    def __init__(self) -> None:
        self.objects: dict[tuple[str, str], dict[str, Any]] = {}
        self.put_calls: list[dict[str, Any]] = []
        self.fail_puts = False
        self.fail_gets = False

    def put_object(self, **kwargs: Any) -> dict[str, Any]:
        if self.fail_puts:
            raise ClientError({"Error": {"Code": "AccessDenied", "Message": "denied"}}, "PutObject")
        body = kwargs["Body"]
        data = body.read() if hasattr(body, "read") else body
        expected = kwargs.get("ChecksumSHA256")
        actual = base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")
        if expected is not None and expected != actual:
            raise ClientError({"Error": {"Code": "BadDigest", "Message": "checksum"}}, "PutObject")
        self.objects[(kwargs["Bucket"], kwargs["Key"])] = {
            "data": data,
            "content_type": kwargs.get("ContentType"),
        }
        self.put_calls.append({k: v for k, v in kwargs.items() if k != "Body"})
        return {}

    def get_object(self, **kwargs: Any) -> dict[str, Any]:
        if self.fail_gets:
            raise ClientError({"Error": {"Code": "InternalError", "Message": "boom"}}, "GetObject")
        stored = self.objects.get((kwargs["Bucket"], kwargs["Key"]))
        if stored is None:
            raise ClientError({"Error": {"Code": "NoSuchKey", "Message": "missing"}}, "GetObject")
        data: bytes = stored["data"]
        return {
            "Body": FakeBody(data),
            "ContentLength": len(data),
            "ContentType": stored["content_type"],
        }
