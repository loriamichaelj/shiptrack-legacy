"""Proof-of-delivery objects in S3 (release v1.1.0).

The modern stack stores proof of delivery in S3. During the migration both stacks read and write the
same `pod_documents` table, so legacy has to read an `s3://` URI as well as a `file://` one. New
legacy uploads still go to local disk, and a sync (scripts/migrate_pod_to_s3.py) moves them across.

# LEGACY AP-05 still holds for new uploads: the file is on the host that received it until the sync
# runs, which is the accepted coexistence window.
"""

from __future__ import annotations

import base64
import uuid
from dataclasses import dataclass
from functools import lru_cache
from typing import Any, Protocol
from urllib.parse import urlparse

import boto3

CHUNK_SIZE = 64 * 1024
NOT_FOUND_CODES = frozenset({"NoSuchKey", "404", "NotFound"})


class S3Client(Protocol):
    """The two S3 calls this application makes, so tests can inject a fake instead of boto3."""

    def get_object(self, **kwargs: Any) -> dict[str, Any]: ...

    def put_object(self, **kwargs: Any) -> dict[str, Any]: ...


@dataclass(frozen=True)
class S3Location:
    bucket: str
    key: str

    @property
    def uri(self) -> str:
        return f"s3://{self.bucket}/{self.key}"


def proof_of_delivery_key(shipment_id: uuid.UUID, document_id: uuid.UUID) -> str:
    """The object key the modern stack uses, so a document has one address on both stacks."""
    return f"pod/{shipment_id}/{document_id}"


def parse_uri(uri: str) -> S3Location | None:
    """Return the bucket and key of an s3:// URI, or None for any other scheme."""
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc:
        return None
    key = parsed.path.lstrip("/")
    return S3Location(bucket=parsed.netloc, key=key) if key else None


def sha256_checksum(hex_digest: str) -> str:
    """S3 wants the SHA-256 as base64 of the raw digest."""
    return base64.b64encode(bytes.fromhex(hex_digest)).decode("ascii")


def is_not_found(error: Exception) -> bool:
    """True for a botocore ClientError that means the object is not there."""
    response = getattr(error, "response", None)
    if not isinstance(response, dict):
        return False
    code = str(response.get("Error", {}).get("Code", ""))
    return code in NOT_FOUND_CODES


@lru_cache(maxsize=1)
def default_client() -> S3Client:
    """The boto3 S3 client, created on first use. The instance role supplies the credentials."""
    client: S3Client = boto3.client("s3")
    return client
