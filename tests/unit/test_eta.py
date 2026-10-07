from datetime import UTC, datetime, timedelta

import pytest

from shiptrack.domain.eta import estimate_delivery
from shiptrack.domain.status import Status

OCCURRED = datetime(2026, 10, 1, 12, 0, tzinfo=UTC)
PROMISED = datetime(2026, 10, 5, 12, 0, tzinfo=UTC)


@pytest.mark.parametrize(
    ("status", "hours"),
    [(Status.PICKED_UP, 72), (Status.IN_TRANSIT, 48), (Status.OUT_FOR_DELIVERY, 8)],
)
def test_offset_rules(status: Status, hours: int) -> None:
    assert estimate_delivery(status, OCCURRED, None, PROMISED) == OCCURRED + timedelta(hours=hours)


def test_delivered_uses_the_event_time() -> None:
    assert estimate_delivery(Status.DELIVERED, OCCURRED, PROMISED, PROMISED) == OCCURRED


def test_exception_adds_a_day_to_the_current_estimate() -> None:
    current = datetime(2026, 10, 3, 0, 0, tzinfo=UTC)
    assert estimate_delivery(Status.EXCEPTION, OCCURRED, current, PROMISED) == current + timedelta(
        hours=24
    )


def test_exception_falls_back_to_the_promised_time() -> None:
    assert estimate_delivery(Status.EXCEPTION, OCCURRED, None, PROMISED) == PROMISED + timedelta(
        hours=24
    )


def test_created_has_no_rule() -> None:
    with pytest.raises(ValueError, match="no ETA rule"):
        estimate_delivery(Status.CREATED, OCCURRED, None, PROMISED)
