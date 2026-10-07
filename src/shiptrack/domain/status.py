"""Shipment status state machine and event decision rules (legacy design §3.3)."""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum


class Status(StrEnum):
    CREATED = "CREATED"
    PICKED_UP = "PICKED_UP"
    IN_TRANSIT = "IN_TRANSIT"
    OUT_FOR_DELIVERY = "OUT_FOR_DELIVERY"
    DELIVERED = "DELIVERED"
    EXCEPTION = "EXCEPTION"


# Statuses a carrier can report. CREATED is only ever the initial state.
EVENT_STATUSES: tuple[Status, ...] = tuple(s for s in Status if s is not Status.CREATED)

_FORWARD_RANK: dict[Status, int] = {
    Status.CREATED: 0,
    Status.PICKED_UP: 1,
    Status.IN_TRANSIT: 2,
    Status.OUT_FOR_DELIVERY: 3,
    Status.DELIVERED: 4,
}
_EXCEPTION_RECOVERY: frozenset[Status] = frozenset({Status.IN_TRANSIT, Status.OUT_FOR_DELIVERY})


def is_valid_transition(current: Status, new: Status) -> bool:
    """Forward moves and forward skips are valid; backward and repeated moves are not.

    EXCEPTION can be entered from any non-terminal status and left only to IN_TRANSIT or
    OUT_FOR_DELIVERY. DELIVERED is terminal.
    """
    if current is Status.DELIVERED or new is Status.CREATED:
        return False
    if current is Status.EXCEPTION:
        return new in _EXCEPTION_RECOVERY
    if new is Status.EXCEPTION:
        return True
    return _FORWARD_RANK[new] > _FORWARD_RANK[current]


class Outcome(StrEnum):
    APPLIED = "APPLIED"
    OUT_OF_ORDER = "OUT_OF_ORDER"
    INVALID = "INVALID"


def decide(
    current: Status,
    last_event_at: datetime | None,
    new: Status,
    occurred_at: datetime,
) -> Outcome:
    """Decide what to do with a non-duplicate event (duplicates are filtered by the database).

    An event older than the latest applied one is out of order; otherwise the transition must
    be valid.
    """
    if last_event_at is not None and occurred_at < last_event_at:
        return Outcome.OUT_OF_ORDER
    if not is_valid_transition(current, new):
        return Outcome.INVALID
    return Outcome.APPLIED
