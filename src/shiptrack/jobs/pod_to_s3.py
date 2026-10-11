"""Move proof-of-delivery files from this host's disk to S3 (release v1.1.0).

Legacy keeps each upload on the host that received it (AP-05). The modern stack reads proof of
delivery from S3, so before the write path moves, every `file://` document is uploaded and its row
rewritten to an `s3://` URI. Run it on each host, because each host holds different files, and then
every minute from cron (ShipTrack-PodSync) while both stacks take traffic.

For each `file://` document whose file is on this host:
1. hash the file and compare it with the stored sha256, so a damaged file is never uploaded;
2. upload it to `pod/{shipment_id}/{document_id}` with the SHA-256 as the object checksum, which S3
   verifies on receipt;
3. rewrite the row's `storage_uri`, only if it still says `file://` (another run may have won).

It is idempotent and resumable: a document is moved by one committed row at a time, a document
already moved is skipped, and a file that is not on this host belongs to the other host.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, sessionmaker

from shiptrack.config import configure_logging, load_settings
from shiptrack.db.models import PodDocument
from shiptrack.db.session import create_db_engine, create_session_factory
from shiptrack.storage import local, s3

logger = logging.getLogger("shiptrack.pod_to_s3")

READ_CHUNK = 1024 * 1024


@dataclass
class Counts:
    migrated: int = 0
    already_migrated: int = 0
    missing_on_this_host: int = 0
    checksum_mismatch: int = 0
    failed: int = 0

    @property
    def ok(self) -> bool:
        return self.checksum_mismatch == 0 and self.failed == 0

    def summary(self, *, dry_run: bool) -> str:
        return (
            f"pod sync {'(dry run) ' if dry_run else ''}"
            f"migrated={self.migrated} already_migrated={self.already_migrated} "
            f"missing_on_this_host={self.missing_on_this_host} "
            f"checksum_mismatch={self.checksum_mismatch} failed={self.failed}"
        )


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(READ_CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def migrate(
    session_factory: sessionmaker[Session],
    client: s3.S3Client,
    bucket: str,
    *,
    dry_run: bool = False,
) -> Counts:
    """Upload every local document file on this host and rewrite its row; return the counts."""
    counts = Counts()

    with session_factory() as session:
        counts.already_migrated = (
            session.scalar(
                select(func.count())
                .select_from(PodDocument)
                .where(PodDocument.storage_uri.like("s3://%"))
            )
            or 0
        )
        pending = session.execute(
            select(
                PodDocument.id,
                PodDocument.shipment_id,
                PodDocument.storage_uri,
                PodDocument.content_type,
                PodDocument.sha256,
            )
            .where(PodDocument.storage_uri.like("file://%"))
            .order_by(PodDocument.uploaded_at)
        ).all()

    for document_id, shipment_id, storage_uri, content_type, stored_sha in pending:
        path = local.path_from_uri(storage_uri)
        if path is None or not path.is_file():
            counts.missing_on_this_host += 1
            continue

        actual = file_sha256(path)
        if actual != stored_sha.strip().lower():
            counts.checksum_mismatch += 1
            logger.error("checksum mismatch, not uploading document=%s", document_id)
            continue

        location = s3.S3Location(bucket=bucket, key=s3.pod_key(shipment_id, document_id))
        if dry_run:
            counts.migrated += 1
            continue

        try:
            with path.open("rb") as handle:
                client.put_object(
                    Bucket=location.bucket,
                    Key=location.key,
                    Body=handle,
                    ContentType=content_type,
                    ChecksumAlgorithm="SHA256",
                    ChecksumSHA256=s3.sha256_checksum(actual),
                )
            with session_factory() as session:
                # Only a row that still says file:// changes, so a concurrent run is harmless.
                session.execute(
                    update(PodDocument)
                    .where(PodDocument.id == document_id, PodDocument.storage_uri == storage_uri)
                    .values(storage_uri=location.uri)
                )
                session.commit()
        except Exception:
            counts.failed += 1
            logger.exception("could not move document=%s", document_id)
            continue
        counts.migrated += 1
        logger.info("moved document=%s", document_id)

    return counts


def run(bucket: str, *, dry_run: bool, client: s3.S3Client | None = None) -> Counts:
    # Cron redirects stdout and stderr to a log file, so log to the console only.
    settings = dataclasses.replace(load_settings(), log_file=None)
    configure_logging(settings)
    engine = create_db_engine(settings)
    try:
        return migrate(
            create_session_factory(engine), client or s3.default_client(), bucket, dry_run=dry_run
        )
    finally:
        engine.dispose()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", maxsplit=1)[0])
    parser.add_argument(
        "--bucket", default=os.environ.get("POD_BUCKET"), help="default: $POD_BUCKET"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="count what would move; change nothing"
    )
    args = parser.parse_args(argv)
    if not args.bucket:
        parser.error("a bucket is required: --bucket or POD_BUCKET")

    counts = run(args.bucket, dry_run=args.dry_run)
    print(counts.summary(dry_run=args.dry_run))
    return 0 if counts.ok else 1


if __name__ == "__main__":
    sys.exit(main())
