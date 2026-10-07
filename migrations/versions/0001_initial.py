"""initial schema and carrier seed

Revision ID: 0001
Revises:
Create Date: 2026-10-07
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

SCHEMA = "shiptrack"
STATUSES = ("CREATED", "PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY", "DELIVERED", "EXCEPTION")
CARRIERS = (
    ("ACME", "Acme Freight"),
    ("BOLT", "Bolt Logistics"),
    ("CRWN", "Crown Carriers"),
    ("MFLT", "Meridian Fleet"),
    ("ZZTEST", "Test traffic only"),
)


def _in_list(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN ({', '.join(repr(v) for v in values)})"


def upgrade() -> None:
    now = sa.text("now()")
    carriers = op.create_table(
        "carriers",
        sa.Column("id", sa.SmallInteger, primary_key=True, autoincrement=True),
        sa.Column("code", sa.String(8), nullable=False, unique=True),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column(
            "created_at", postgresql.TIMESTAMP(timezone=True), server_default=now, nullable=False
        ),
        schema=SCHEMA,
    )

    op.create_table(
        "shipments",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column("tracking_number", sa.String(12), nullable=False, unique=True),
        sa.Column(
            "carrier_id", sa.SmallInteger, sa.ForeignKey(f"{SCHEMA}.carriers.id"), nullable=False
        ),
        sa.Column("origin", sa.String(100), nullable=False),
        sa.Column("destination", sa.String(100), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default=sa.text("'CREATED'")),
        sa.Column("promised_delivery_at", postgresql.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("estimated_delivery_at", postgresql.TIMESTAMP(timezone=True)),
        sa.Column("delivered_at", postgresql.TIMESTAMP(timezone=True)),
        sa.Column("last_event_at", postgresql.TIMESTAMP(timezone=True)),
        sa.Column("sla_breached", sa.Boolean, nullable=False, server_default=sa.text("false")),
        sa.Column("sla_breached_at", postgresql.TIMESTAMP(timezone=True)),
        sa.Column(
            "created_at", postgresql.TIMESTAMP(timezone=True), server_default=now, nullable=False
        ),
        sa.Column(
            "updated_at", postgresql.TIMESTAMP(timezone=True), server_default=now, nullable=False
        ),
        sa.CheckConstraint(_in_list("status", STATUSES), name="ck_shipments_status"),
        schema=SCHEMA,
    )
    op.create_index("ix_shipments_carrier_id", "shipments", ["carrier_id"], schema=SCHEMA)
    op.create_index("ix_shipments_created_at_id", "shipments", ["created_at", "id"], schema=SCHEMA)
    op.create_index(
        "ix_shipments_sla_scan",
        "shipments",
        ["promised_delivery_at"],
        schema=SCHEMA,
        postgresql_where=sa.text("status <> 'DELIVERED' AND NOT sla_breached"),
    )

    op.create_table(
        "tracking_events",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column(
            "shipment_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey(f"{SCHEMA}.shipments.id"),
            nullable=False,
        ),
        sa.Column("event_type", sa.String(20), nullable=False),
        sa.Column("location", sa.String(100), nullable=False),
        sa.Column("occurred_at", postgresql.TIMESTAMP(timezone=True), nullable=False),
        sa.Column(
            "received_at", postgresql.TIMESTAMP(timezone=True), server_default=now, nullable=False
        ),
        sa.Column("idempotency_key", sa.String(64), nullable=False, unique=True),
        sa.Column("applied", sa.Boolean, nullable=False),
        sa.Column("payload", postgresql.JSONB),
        sa.CheckConstraint(_in_list("event_type", STATUSES[1:]), name="ck_tracking_events_type"),
        schema=SCHEMA,
    )
    op.create_index(
        "ix_tracking_events_shipment_occurred",
        "tracking_events",
        ["shipment_id", "occurred_at"],
        schema=SCHEMA,
    )

    op.create_table(
        "pod_documents",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "shipment_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey(f"{SCHEMA}.shipments.id"),
            nullable=False,
        ),
        sa.Column("storage_uri", sa.Text, nullable=False),
        sa.Column("content_type", sa.String(50), nullable=False),
        sa.Column("size_bytes", sa.BigInteger, nullable=False),
        sa.Column("sha256", postgresql.CHAR(64), nullable=False),
        sa.Column(
            "uploaded_at", postgresql.TIMESTAMP(timezone=True), server_default=now, nullable=False
        ),
        schema=SCHEMA,
    )

    # LEGACY AP-09: deliberately no unique constraint on shipment_id.
    op.create_table(
        "sla_alerts",
        sa.Column("id", sa.BigInteger, primary_key=True, autoincrement=True),
        sa.Column(
            "shipment_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey(f"{SCHEMA}.shipments.id"),
            nullable=False,
        ),
        sa.Column(
            "detected_at", postgresql.TIMESTAMP(timezone=True), server_default=now, nullable=False
        ),
        sa.Column("detected_by", sa.String(64), nullable=False),
        schema=SCHEMA,
    )

    op.bulk_insert(carriers, [{"code": code, "name": name} for code, name in CARRIERS])


def downgrade() -> None:
    for table in ("sla_alerts", "pod_documents", "tracking_events", "shipments", "carriers"):
        op.drop_table(table, schema=SCHEMA)
