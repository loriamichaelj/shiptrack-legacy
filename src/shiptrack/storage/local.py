"""Local-disk proof-of-delivery storage.

# LEGACY AP-05: files live on whichever host received the upload. The ALB's stickiness on
# tg-legacy hides this; without the cookie, about half of the reads return 404.
"""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO
from urllib.parse import unquote, urlparse

CHUNK_SIZE = 64 * 1024


class PayloadTooLargeError(Exception):
    pass


@dataclass(frozen=True)
class StoredFile:
    path: Path
    size_bytes: int
    sha256: str

    @property
    def uri(self) -> str:
        return self.path.as_uri()


def pod_path(pod_dir: Path, shipment_id: uuid.UUID, document_id: uuid.UUID) -> Path:
    return pod_dir / str(shipment_id) / str(document_id)


def save(
    pod_dir: Path,
    shipment_id: uuid.UUID,
    document_id: uuid.UUID,
    stream: BinaryIO,
    max_bytes: int,
) -> StoredFile:
    """Stream `stream` to disk, computing size and sha256; reject anything over max_bytes."""
    path = pod_path(pod_dir, shipment_id, document_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("wb") as out:
            while chunk := stream.read(CHUNK_SIZE):
                size += len(chunk)
                if size > max_bytes:
                    raise PayloadTooLargeError
                digest.update(chunk)
                out.write(chunk)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return StoredFile(path=path, size_bytes=size, sha256=digest.hexdigest())


def path_from_uri(uri: str) -> Path | None:
    """Return the local path for a file:// URI, or None for any other scheme."""
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        return None
    return Path(unquote(parsed.path))
