"""AP-06: the in-process queue loses whatever is still queued when the process stops."""

import threading
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from typing import Any

import pytest

from shiptrack.domain.status import Status
from shiptrack.events import processor as processor_module
from shiptrack.events.processor import ApplyResult, EventProcessor, QueuedEvent


def event(key: str) -> QueuedEvent:
    return QueuedEvent(
        shipment_id=uuid.uuid4(),
        idempotency_key=key,
        event_type=Status.PICKED_UP,
        location="X",
        occurred_at=datetime(2026, 10, 1, tzinfo=UTC),
        payload=None,
    )


class FakeSession:
    pass


@contextmanager
def fake_factory() -> Iterator[FakeSession]:
    yield FakeSession()


def make_processor() -> EventProcessor:
    return EventProcessor(fake_factory)  # type: ignore[arg-type]


def test_events_are_applied_in_order(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[str] = []

    def fake_apply(_: Any, item: QueuedEvent) -> ApplyResult:
        seen.append(item.idempotency_key)
        return ApplyResult.APPLIED

    monkeypatch.setattr(processor_module, "apply_event", fake_apply)
    proc = make_processor()
    proc.start()
    for key in ("a", "b", "c"):
        proc.submit(event(key))
    assert proc.drain(timeout=5)
    proc.stop()
    assert seen == ["a", "b", "c"]


def test_a_failing_event_is_lost_but_the_worker_survives(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[str] = []

    def fake_apply(_: Any, item: QueuedEvent) -> ApplyResult:
        if item.idempotency_key == "bad":
            raise RuntimeError("database is down")
        seen.append(item.idempotency_key)
        return ApplyResult.APPLIED

    monkeypatch.setattr(processor_module, "apply_event", fake_apply)
    proc = make_processor()
    proc.start()
    for key in ("a", "bad", "c"):
        proc.submit(event(key))
    assert proc.drain(timeout=5)
    proc.stop()
    assert seen == ["a", "c"]


def test_queued_events_are_dropped_when_the_process_stops(monkeypatch: pytest.MonkeyPatch) -> None:
    started, release = threading.Event(), threading.Event()
    seen: list[str] = []

    def fake_apply(_: Any, item: QueuedEvent) -> ApplyResult:
        started.set()
        release.wait(timeout=5)
        seen.append(item.idempotency_key)
        return ApplyResult.APPLIED

    monkeypatch.setattr(processor_module, "apply_event", fake_apply)
    proc = make_processor()
    proc.start()
    for key in ("a", "b", "c"):
        proc.submit(event(key))
    assert started.wait(timeout=5)  # "a" is in flight; "b" and "c" are still queued

    stopper = threading.Thread(target=proc.stop)
    stopper.start()
    release.set()
    stopper.join(timeout=10)
    assert seen == ["a"]  # the restart lost "b" and "c"
