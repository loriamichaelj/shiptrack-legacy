from datetime import UTC, datetime, timedelta
from itertools import product

import pytest

from shiptrack.domain.status import (
    EVENT_STATUSES,
    Outcome,
    Status,
    decide,
    is_valid_transition,
)

S = Status
VALID_PAIRS = {
    (S.CREATED, S.PICKED_UP),
    (S.CREATED, S.IN_TRANSIT),
    (S.CREATED, S.OUT_FOR_DELIVERY),
    (S.CREATED, S.DELIVERED),
    (S.CREATED, S.EXCEPTION),
    (S.PICKED_UP, S.IN_TRANSIT),
    (S.PICKED_UP, S.OUT_FOR_DELIVERY),
    (S.PICKED_UP, S.DELIVERED),
    (S.PICKED_UP, S.EXCEPTION),
    (S.IN_TRANSIT, S.OUT_FOR_DELIVERY),
    (S.IN_TRANSIT, S.DELIVERED),
    (S.IN_TRANSIT, S.EXCEPTION),
    (S.OUT_FOR_DELIVERY, S.DELIVERED),
    (S.OUT_FOR_DELIVERY, S.EXCEPTION),
    (S.EXCEPTION, S.IN_TRANSIT),
    (S.EXCEPTION, S.OUT_FOR_DELIVERY),
}


@pytest.mark.parametrize(("current", "new"), list(product(Status, Status)))
def test_every_transition_pair(current: Status, new: Status) -> None:
    assert is_valid_transition(current, new) is ((current, new) in VALID_PAIRS)


def test_event_statuses_exclude_created() -> None:
    assert Status.CREATED not in EVENT_STATUSES
    assert set(EVENT_STATUSES) == set(Status) - {Status.CREATED}


T0 = datetime(2026, 10, 1, 12, 0, tzinfo=UTC)


def test_first_event_is_applied() -> None:
    assert decide(S.CREATED, None, S.PICKED_UP, T0) is Outcome.APPLIED


def test_older_event_is_out_of_order() -> None:
    assert decide(S.IN_TRANSIT, T0, S.OUT_FOR_DELIVERY, T0 - timedelta(seconds=1)) is (
        Outcome.OUT_OF_ORDER
    )


def test_same_timestamp_is_not_out_of_order() -> None:
    assert decide(S.IN_TRANSIT, T0, S.OUT_FOR_DELIVERY, T0) is Outcome.APPLIED


def test_backward_move_is_invalid() -> None:
    assert decide(S.IN_TRANSIT, T0, S.PICKED_UP, T0 + timedelta(hours=1)) is Outcome.INVALID


def test_out_of_order_is_decided_before_invalid() -> None:
    # An old event that would also be an invalid transition is reported as out of order.
    assert decide(S.IN_TRANSIT, T0, S.PICKED_UP, T0 - timedelta(hours=1)) is Outcome.OUT_OF_ORDER


def test_nothing_follows_delivered() -> None:
    later = T0 + timedelta(hours=1)
    for new in EVENT_STATUSES:
        assert decide(S.DELIVERED, T0, new, later) is Outcome.INVALID
