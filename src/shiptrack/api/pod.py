"""Proof-of-delivery upload and download."""

from __future__ import annotations

import logging
import uuid
from collections.abc import Iterator
from typing import Annotated

from fastapi import APIRouter, Depends, File, Request, UploadFile
from fastapi.responses import FileResponse, Response, StreamingResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from shiptrack.api.deps import get_shipment_or_404, parse_uuid
from shiptrack.api.errors import ApiError, not_found
from shiptrack.config import Settings
from shiptrack.db.models import PodDocument
from shiptrack.db.session import get_session
from shiptrack.domain.models import PodOut
from shiptrack.storage import local, s3

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1")

MAX_POD_BYTES = 10 * 1024 * 1024
ALLOWED_CONTENT_TYPES = frozenset({"application/pdf", "image/png", "image/jpeg"})

SessionDep = Annotated[Session, Depends(get_session)]


def get_s3_client() -> s3.S3Client:
    """The S3 client; a dependency so that tests can replace it."""
    return s3.default_client()


S3Dep = Annotated[s3.S3Client, Depends(get_s3_client)]


@router.post("/shipments/{shipment_id}/pod", status_code=201, response_model=PodOut)
def upload_pod(
    shipment_id: str,
    request: Request,
    session: SessionDep,
    file: Annotated[UploadFile, File()],
) -> PodOut:
    shipment = get_shipment_or_404(session, shipment_id)
    content_type = (file.content_type or "").split(";")[0].strip().lower()
    if content_type not in ALLOWED_CONTENT_TYPES:
        raise ApiError(
            415, "UNSUPPORTED_MEDIA_TYPE", "Only application/pdf, image/png, image/jpeg allowed"
        )

    settings: Settings = request.app.state.settings
    document_id = uuid.uuid4()
    try:
        stored = local.save(settings.pod_dir, shipment.id, document_id, file.file, MAX_POD_BYTES)
    except local.PayloadTooLargeError as exc:
        raise ApiError(413, "PAYLOAD_TOO_LARGE", "POD files are limited to 10 MiB") from exc

    document = PodDocument(
        id=document_id,
        shipment_id=shipment.id,
        storage_uri=stored.uri,
        content_type=content_type,
        size_bytes=stored.size_bytes,
        sha256=stored.sha256,
    )
    session.add(document)
    try:
        session.commit()
    except Exception:
        session.rollback()
        stored.path.unlink(missing_ok=True)
        raise
    session.refresh(document)
    return PodOut(
        document_id=document.id,
        shipment_id=document.shipment_id,
        content_type=document.content_type,
        size_bytes=document.size_bytes,
        sha256=document.sha256,
        uploaded_at=document.uploaded_at,
    )


def _stream_from_s3(client: s3.S3Client, location: s3.S3Location, content_type: str) -> Response:
    """Stream an S3 object with the same 200 and bytes contract as a local file."""
    try:
        result = client.get_object(Bucket=location.bucket, Key=location.key)
    except Exception as exc:
        if s3.is_not_found(exc):
            raise not_found("Document not found") from exc
        logger.exception("could not read %s from S3", location.uri)
        raise ApiError(500, "INTERNAL", "Storage unavailable") from exc

    body = result["Body"]

    def chunks() -> Iterator[bytes]:
        try:
            yield from body.iter_chunks(s3.CHUNK_SIZE)
        finally:
            body.close()

    headers = {}
    if "ContentLength" in result:
        headers["Content-Length"] = str(result["ContentLength"])
    return StreamingResponse(chunks(), media_type=content_type, headers=headers)


@router.get("/shipments/{shipment_id}/pod/{document_id}", response_model=None)
def download_pod(
    shipment_id: str, document_id: str, session: SessionDep, s3_client: S3Dep
) -> Response:
    document = session.scalar(
        select(PodDocument).where(
            PodDocument.id == parse_uuid(document_id, "Document"),
            PodDocument.shipment_id == parse_uuid(shipment_id),
        )
    )
    if document is None:
        raise not_found("Document not found")

    # v1.1.0: a document the sync has moved is read from S3, wherever it was uploaded.
    location = s3.parse_uri(document.storage_uri)
    if location is not None:
        return _stream_from_s3(s3_client, location, document.content_type)

    path = local.path_from_uri(document.storage_uri)
    if path is None:
        logger.error("unsupported storage uri for document %s", document.id)
        raise ApiError(500, "INTERNAL", "Unsupported storage location")
    # LEGACY AP-05: the file exists only on the host that received the upload.
    if not path.is_file():
        raise not_found("Document not found")
    return FileResponse(path, media_type=document.content_type)
