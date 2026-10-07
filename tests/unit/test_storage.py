import hashlib
import io
import uuid
from pathlib import Path

import pytest

from shiptrack.storage import local


def test_save_records_size_and_sha256(tmp_path: Path) -> None:
    data = b"proof of delivery" * 1000
    shipment_id, document_id = uuid.uuid4(), uuid.uuid4()
    stored = local.save(tmp_path, shipment_id, document_id, io.BytesIO(data), max_bytes=10**6)
    assert stored.size_bytes == len(data)
    assert stored.sha256 == hashlib.sha256(data).hexdigest()
    assert stored.path == tmp_path / str(shipment_id) / str(document_id)
    assert stored.path.read_bytes() == data


def test_too_large_is_rejected_and_nothing_is_left_behind(tmp_path: Path) -> None:
    shipment_id, document_id = uuid.uuid4(), uuid.uuid4()
    with pytest.raises(local.PayloadTooLargeError):
        local.save(tmp_path, shipment_id, document_id, io.BytesIO(b"x" * 101), max_bytes=100)
    assert not local.pod_path(tmp_path, shipment_id, document_id).exists()


def test_exactly_the_limit_is_accepted(tmp_path: Path) -> None:
    stored = local.save(tmp_path, uuid.uuid4(), uuid.uuid4(), io.BytesIO(b"x" * 100), 100)
    assert stored.size_bytes == 100


def test_uri_round_trip(tmp_path: Path) -> None:
    stored = local.save(tmp_path, uuid.uuid4(), uuid.uuid4(), io.BytesIO(b"abc"), 100)
    assert stored.uri.startswith("file:///")
    assert local.path_from_uri(stored.uri) == stored.path


def test_other_schemes_are_not_local() -> None:
    assert local.path_from_uri("s3://bucket/pod/a/b") is None
