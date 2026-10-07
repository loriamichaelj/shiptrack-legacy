"""SQLAlchemy ORM models. The Alembic migration is the source of truth for the schema."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    ForeignKey,
    Index,
    MetaData,
    SmallInteger,
    String,
    Text,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import CHAR, JSONB, TIMESTAMP
from sqlalchemy.dialects.postgresql import UUID as PG_UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

SCHEMA = "shiptrack"

SHIPMENT_STATUSES = (
    "CREATED",
    "PICKED_UP",
    "IN_TRANSIT",
    "OUT_FOR_DELIVERY",
    "DELIVERED",
    "EXCEPTION",
)
EVENT_TYPES = SHIPMENT_STATUSES[1:]


def _in_list(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN ({', '.join(repr(v) for v in values)})"


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class Carrier(Base):
    __tablename__ = "carriers"

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True, autoincrement=True)
    code: Mapped[str] = mapped_column(String(8), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), server_default=func.now(), nullable=False
    )


class Shipment(Base):
    __tablename__ = "shipments"
    __table_args__ = (
        CheckConstraint(_in_list("status", SHIPMENT_STATUSES), name="ck_shipments_status"),
        Index("ix_shipments_carrier_id", "carrier_id"),
        Index("ix_shipments_created_at_id", "created_at", "id"),
        Index(
            "ix_shipments_sla_scan",
            "promised_delivery_at",
            postgresql_where=text("status <> 'DELIVERED' AND NOT sla_breached"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    tracking_number: Mapped[str] = mapped_column(String(12), unique=True, nullable=False)
    carrier_id: Mapped[int] = mapped_column(
        SmallInteger, ForeignKey(f"{SCHEMA}.carriers.id"), nullable=False
    )
    origin: Mapped[str] = mapped_column(String(100), nullable=False)
    destination: Mapped[str] = mapped_column(String(100), nullable=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, server_default=text("'CREATED'")
    )
    promised_delivery_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)
    estimated_delivery_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    delivered_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    last_event_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    sla_breached: Mapped[bool] = mapped_column(
        Boolean, nullable=False, server_default=text("false")
    )
    sla_breached_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), server_default=func.now(), nullable=False
    )

    carrier: Mapped[Carrier] = relationship(lazy="selectin")


class TrackingEvent(Base):
    __tablename__ = "tracking_events"
    __table_args__ = (
        CheckConstraint(_in_list("event_type", EVENT_TYPES), name="ck_tracking_events_type"),
        Index("ix_tracking_events_shipment_occurred", "shipment_id", "occurred_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    shipment_id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), ForeignKey(f"{SCHEMA}.shipments.id"), nullable=False
    )
    event_type: Mapped[str] = mapped_column(String(20), nullable=False)
    location: Mapped[str] = mapped_column(String(100), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)
    received_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), server_default=func.now(), nullable=False
    )
    idempotency_key: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    applied: Mapped[bool] = mapped_column(Boolean, nullable=False)
    payload: Mapped[dict[str, Any] | None] = mapped_column(JSONB)


class PodDocument(Base):
    __tablename__ = "pod_documents"

    id: Mapped[uuid.UUID] = mapped_column(PG_UUID(as_uuid=True), primary_key=True)
    shipment_id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), ForeignKey(f"{SCHEMA}.shipments.id"), nullable=False
    )
    storage_uri: Mapped[str] = mapped_column(Text, nullable=False)
    content_type: Mapped[str] = mapped_column(String(50), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    sha256: Mapped[str] = mapped_column(CHAR(64), nullable=False)
    uploaded_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), server_default=func.now(), nullable=False
    )


class SlaAlert(Base):
    """# LEGACY AP-09: deliberately no unique constraint on shipment_id, so duplicates show."""

    __tablename__ = "sla_alerts"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    shipment_id: Mapped[uuid.UUID] = mapped_column(
        PG_UUID(as_uuid=True), ForeignKey(f"{SCHEMA}.shipments.id"), nullable=False
    )
    detected_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), server_default=func.now(), nullable=False
    )
    detected_by: Mapped[str] = mapped_column(String(64), nullable=False)
