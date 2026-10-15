"""Release v1.1.0: a proof-of-delivery document whose row says s3:// is read from S3."""

import hashlib
import uuid
from collections.abc import Callable, Iterator
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text

from shiptrack.api.proof_of_delivery import get_s3_client
from shiptrack.jobs.proof_of_delivery_to_s3 import migrate
from shiptrack.storage import s3
from tests.fake_s3 import FakeS3

MakeShipment = Callable[..., dict[str, Any]]
BUCKET = "shiptrack-pod-test"
PNG = b"\x89PNG\r\n\x1a\n" + b"pod" * 200


@pytest.fixture()
def fake_s3(client: TestClient) -> Iterator[FakeS3]:
    fake = FakeS3()
    client.app.dependency_overrides[get_s3_client] = lambda: fake  # type: ignore[attr-defined]
    yield fake
    client.app.dependency_overrides.clear()  # type: ignore[attr-defined]


def upload(client: TestClient, shipment_id: str) -> dict[str, Any]:
    response = client.post(
        f"/api/v1/shipments/{shipment_id}/pod", files={"file": ("pod.png", PNG, "image/png")}
    )
    assert response.status_code == 201, response.text
    return dict(response.json())


def set_uri(engine: Engine, document_id: str, uri: str) -> None:
    with engine.begin() as connection:
        connection.execute(
            text("UPDATE shiptrack.pod_documents SET storage_uri = :uri WHERE id = :id"),
            {"uri": uri, "id": document_id},
        )


def test_a_moved_document_streams_from_s3_with_the_same_contract(
    client: TestClient, make_shipment: MakeShipment, fake_s3: FakeS3
) -> None:
    sid = make_shipment()["id"]
    document = upload(client, sid)
    counts = migrate(client.app.state.session_factory, fake_s3, BUCKET)  # type: ignore[attr-defined]
    assert counts.migrated == 1

    response = client.get(f"/api/v1/shipments/{sid}/pod/{document['document_id']}")
    assert response.status_code == 200
    assert response.content == PNG
    assert response.headers["content-type"] == "image/png"
    assert response.headers["content-length"] == str(len(PNG))


def test_a_document_uploaded_elsewhere_is_readable_on_this_host(
    client: TestClient, make_shipment: MakeShipment, fake_s3: FakeS3, engine: Engine
) -> None:
    """The sync ran on the other host: this host has no file, and the row says s3://."""
    sid = make_shipment()["id"]
    document = upload(client, sid)
    key = s3.proof_of_delivery_key(uuid.UUID(sid), uuid.UUID(document["document_id"]))
    fake_s3.put_object(Bucket=BUCKET, Key=key, Body=PNG, ContentType="image/png")
    set_uri(engine, document["document_id"], f"s3://{BUCKET}/{key}")
    # Remove the local file as if it had never been on this host.
    for path in (client.app.state.settings.proof_of_delivery_dir).rglob("*"):  # type: ignore[attr-defined]
        if path.is_file():
            path.unlink()

    response = client.get(f"/api/v1/shipments/{sid}/pod/{document['document_id']}")
    assert response.status_code == 200
    assert hashlib.sha256(response.content).hexdigest() == hashlib.sha256(PNG).hexdigest()


def test_a_missing_object_is_404(
    client: TestClient, make_shipment: MakeShipment, fake_s3: FakeS3, engine: Engine
) -> None:
    sid = make_shipment()["id"]
    document = upload(client, sid)
    set_uri(engine, document["document_id"], f"s3://{BUCKET}/pod/missing")

    response = client.get(f"/api/v1/shipments/{sid}/pod/{document['document_id']}")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


def test_an_s3_failure_is_a_500_not_a_404(
    client: TestClient, make_shipment: MakeShipment, fake_s3: FakeS3, engine: Engine
) -> None:
    sid = make_shipment()["id"]
    document = upload(client, sid)
    set_uri(engine, document["document_id"], f"s3://{BUCKET}/pod/anything")
    fake_s3.fail_gets = True

    response = client.get(f"/api/v1/shipments/{sid}/pod/{document['document_id']}")
    assert response.status_code == 500
    assert response.json()["error"]["code"] == "INTERNAL"


def test_a_local_document_is_still_served_from_disk(
    client: TestClient, make_shipment: MakeShipment, fake_s3: FakeS3
) -> None:
    sid = make_shipment()["id"]
    document = upload(client, sid)
    response = client.get(f"/api/v1/shipments/{sid}/pod/{document['document_id']}")
    assert response.status_code == 200
    assert response.content == PNG
    assert fake_s3.put_calls == []
