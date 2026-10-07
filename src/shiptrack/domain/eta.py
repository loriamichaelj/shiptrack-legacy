"""Estimated delivery rules (legacy design §3.3)."""

from __future__ import annotations

from datetime import datetime, timedelta

from shiptrack.domain.status import Status

_OFFSETS: dict[Status, timedelta] = {
    Status.PICKED_UP: timedelta(hours=72),
    Status.IN_TRANSIT: timedelta(hours=48),
    Status.OUT_FOR_DELIVERY: timedelta(hours=8),
}
EXCEPTION_DELAY = timedelta(hours=24)


def estimate_delivery(
    status: Status,
    occurred_at: datetime,
    current_estimate: datetime | None,
    promised: datetime,
) -> datetime:
    """Return the new estimated_delivery_at for a shipment that just moved to `status`."""
    if status is Status.DELIVERED:
        return occurred_at
    if status is Status.EXCEPTION:
        return (current_estimate or promised) + EXCEPTION_DELAY
    try:
        return occurred_at + _OFFSETS[status]
    except KeyError as exc:
        raise ValueError(f"no ETA rule for status {status}") from exc
