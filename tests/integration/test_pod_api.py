import hashlib
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient
from sqlalchemy import Engine, text

MakeShipment = Callable[..., dict[str, Any]]
PNG = b"\x89PNG\r\n\x1a\n" + b"pod" * 100


def upload(
    client: TestClient,
    shipment_id: str,
    data: bytes = PNG,
    content_type: str = "image/png",
) -> Any:
    return client.post(
        f"/api/v1/shipments/{shipment_id}/pod",
        files={"file": ("pod.bin", data, content_type)},
    )


def test_upload_and_download(client: TestClient, make_shipment: MakeShipment) -> None:
    sid = make_shipment()["id"]
    response = upload(client, sid)
    assert response.status_code == 201
    body = response.json()
    assert set(body) == {
        "document_id",
        "shipment_id",
        "content_type",
        "size_bytes",
        "sha256",
        "uploaded_at",
    }
    assert body["shipment_id"] == sid
    assert body["content_type"] == "image/png"
    assert body["size_bytes"] == len(PNG)
    assert body["sha256"] == hashlib.sha256(PNG).hexdigest()
    assert body["uploaded_at"].endswith("Z")

    download = client.get(f"/api/v1/shipments/{sid}/pod/{body['document_id']}")
    assert download.status_code == 200
    assert download.headers["content-type"] == "image/png"
    assert download.content == PNG


def test_pdf_and_jpeg_are_accepted(client: TestClient, make_shipment: MakeShipment) -> None:
    sid = make_shipment()["id"]
    for content_type in ("application/pdf", "image/jpeg"):
        assert upload(client, sid, b"data", content_type).status_code == 201


def test_unsupported_media_type(client: TestClient, make_shipment: MakeShipment) -> None:
    sid = make_shipment()["id"]
    response = upload(client, sid, b"hello", "text/plain")
    assert response.status_code == 415
    assert response.json()["error"]["code"] == "UNSUPPORTED_MEDIA_TYPE"


def test_payload_too_large(client: TestClient, make_shipment: MakeShipment, settings: Any) -> None:
    sid = make_shipment()["id"]
    exactly = upload(client, sid, b"x" * (10 * 1024 * 1024), "application/pdf")
    assert exactly.status_code == 201
    too_big = upload(client, sid, b"x" * (10 * 1024 * 1024 + 1), "application/pdf")
    assert too_big.status_code == 413
    assert too_big.json()["error"]["code"] == "PAYLOAD_TOO_LARGE"
    # The rejected upload leaves nothing behind.
    stored = list((Path(settings.pod_dir) / sid).iterdir())
    assert len(stored) == 1


def test_upload_for_unknown_shipment(client: TestClient) -> None:
    response = upload(client, str(uuid.uuid4()))
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


def test_missing_file_part(client: TestClient, make_shipment: MakeShipment) -> None:
    sid = make_shipment()["id"]
    response = client.post(f"/api/v1/shipments/{sid}/pod")
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_download_unknown_document(client: TestClient, make_shipment: MakeShipment) -> None:
    sid = make_shipment()["id"]
    for document_id in (str(uuid.uuid4()), "nope"):
        response = client.get(f"/api/v1/shipments/{sid}/pod/{document_id}")
        assert response.status_code == 404


def test_document_belongs_to_its_shipment(client: TestClient, make_shipment: MakeShipment) -> None:
    first, second = make_shipment()["id"], make_shipment()["id"]
    document_id = upload(client, first).json()["document_id"]
    assert client.get(f"/api/v1/shipments/{second}/pod/{document_id}").status_code == 404


def test_file_missing_on_this_host_is_404(
    client: TestClient, make_shipment: MakeShipment, settings: Any
) -> None:
    """AP-05: a POD uploaded to another host is simply not here."""
    sid = make_shipment()["id"]
    document_id = upload(client, sid).json()["document_id"]
    (Path(settings.pod_dir) / sid / document_id).unlink()
    response = client.get(f"/api/v1/shipments/{sid}/pod/{document_id}")
    assert response.status_code == 404


def test_storage_uri_is_a_local_file_uri(
    client: TestClient, make_shipment: MakeShipment, engine: Engine
) -> None:
    sid = make_shipment()["id"]
    upload(client, sid)
    with engine.connect() as connection:
        uri = connection.scalar(text("SELECT storage_uri FROM shiptrack.pod_documents"))
    assert uri.startswith("file:///")
