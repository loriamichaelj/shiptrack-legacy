"""The POD sync job: move a host's files to S3 and rewrite their rows."""

import base64
import hashlib
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text

from shiptrack.jobs.pod_to_s3 import Counts, migrate
from shiptrack.storage import s3
from tests.fake_s3 import FakeS3

MakeShipment = Callable[..., dict[str, Any]]
BUCKET = "shiptrack-pod-test"


def png(seed: str) -> bytes:
    return b"\x89PNG\r\n\x1a\n" + seed.encode() * 50


def upload(client: TestClient, shipment_id: str, data: bytes) -> dict[str, Any]:
    response = client.post(
        f"/api/v1/shipments/{shipment_id}/pod", files={"file": ("pod.png", data, "image/png")}
    )
    assert response.status_code == 201, response.text
    return dict(response.json())


def uri_of(engine: Engine, document_id: str) -> str:
    with engine.connect() as connection:
        return str(
            connection.execute(
                text("SELECT storage_uri FROM shiptrack.pod_documents WHERE id = :id"),
                {"id": document_id},
            ).scalar_one()
        )


def run(client: TestClient, fake: FakeS3, *, dry_run: bool = False) -> Counts:
    return migrate(
        client.app.state.session_factory,  # type: ignore[attr-defined]
        fake,
        BUCKET,
        dry_run=dry_run,
    )


@pytest.fixture()
def fake() -> FakeS3:
    return FakeS3()


def test_a_local_document_is_uploaded_and_its_row_rewritten(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3, engine: Engine
) -> None:
    sid = make_shipment()["id"]
    data = png("a")
    document = upload(client, sid, data)

    counts = run(client, fake)

    key = s3.pod_key(uuid.UUID(sid), uuid.UUID(document["document_id"]))
    assert counts == Counts(migrated=1)
    assert fake.objects[(BUCKET, key)]["data"] == data
    assert uri_of(engine, document["document_id"]) == f"s3://{BUCKET}/{key}"


def test_the_object_carries_the_sha256_so_s3_verifies_the_upload(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3
) -> None:
    data = png("b")
    upload(client, make_shipment()["id"], data)
    run(client, fake)

    call = fake.put_calls[0]
    assert call["ChecksumAlgorithm"] == "SHA256"
    assert call["ChecksumSHA256"] == base64.b64encode(hashlib.sha256(data).digest()).decode()
    assert call["ContentType"] == "image/png"


def test_a_second_run_changes_nothing(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3
) -> None:
    upload(client, make_shipment()["id"], png("c"))
    first = run(client, fake)
    puts = len(fake.put_calls)

    second = run(client, fake)

    assert first.migrated == 1
    assert second == Counts(already_migrated=1)
    assert len(fake.put_calls) == puts


def test_a_dry_run_counts_and_changes_nothing(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3, engine: Engine
) -> None:
    document = upload(client, make_shipment()["id"], png("d"))
    before = uri_of(engine, document["document_id"])

    counts = run(client, fake, dry_run=True)

    assert counts.migrated == 1
    assert fake.put_calls == []
    assert uri_of(engine, document["document_id"]) == before


def test_a_file_that_is_not_on_this_host_is_counted_and_left_alone(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3, engine: Engine
) -> None:
    document = upload(client, make_shipment()["id"], png("e"))
    for path in client.app.state.settings.pod_dir.rglob("*"):  # type: ignore[attr-defined]
        if path.is_file():
            path.unlink()

    counts = run(client, fake)

    assert counts == Counts(missing_on_this_host=1)
    assert uri_of(engine, document["document_id"]).startswith("file://")
    assert counts.ok


def test_a_damaged_file_is_never_uploaded(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3, engine: Engine
) -> None:
    document = upload(client, make_shipment()["id"], png("f"))
    files = [p for p in client.app.state.settings.pod_dir.rglob("*") if p.is_file()]  # type: ignore[attr-defined]
    files[0].write_bytes(b"damaged")

    counts = run(client, fake)

    assert counts.checksum_mismatch == 1
    assert not counts.ok
    assert fake.put_calls == []
    assert uri_of(engine, document["document_id"]).startswith("file://")


def test_an_upload_failure_leaves_the_row_and_the_file_in_place(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3, engine: Engine
) -> None:
    document = upload(client, make_shipment()["id"], png("g"))
    fake.fail_puts = True

    counts = run(client, fake)

    assert counts.failed == 1
    assert not counts.ok
    assert uri_of(engine, document["document_id"]).startswith("file://")
    # The next run, with S3 healthy again, finishes the job.
    fake.fail_puts = False
    assert run(client, fake).migrated == 1


def test_a_row_changed_by_another_run_is_not_overwritten(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3, engine: Engine
) -> None:
    """The update only matches a row that still has the file:// URI it was read with."""
    document = upload(client, make_shipment()["id"], png("h"))
    other = f"s3://{BUCKET}/pod/set-by-the-other-host"

    real_put = fake.put_object

    def put_then_other_host_wins(**kwargs: Any) -> dict[str, Any]:
        result = real_put(**kwargs)
        with engine.begin() as connection:
            connection.execute(
                text("UPDATE shiptrack.pod_documents SET storage_uri = :u WHERE id = :id"),
                {"u": other, "id": document["document_id"]},
            )
        return result

    fake.put_object = put_then_other_host_wins  # type: ignore[method-assign]
    run(client, fake)

    assert uri_of(engine, document["document_id"]) == other


def test_many_documents_are_moved_independently(
    client: TestClient, make_shipment: MakeShipment, fake: FakeS3, engine: Engine, tmp_path: Path
) -> None:
    ids = [upload(client, make_shipment()["id"], png(str(i)))["document_id"] for i in range(5)]
    # One is not on this host.
    files = sorted(p for p in client.app.state.settings.pod_dir.rglob("*") if p.is_file())  # type: ignore[attr-defined]
    files[0].unlink()

    counts = run(client, fake)

    assert counts.migrated == 4
    assert counts.missing_on_this_host == 1
    moved = [uri_of(engine, i).startswith("s3://") for i in ids]
    assert sum(moved) == 4
