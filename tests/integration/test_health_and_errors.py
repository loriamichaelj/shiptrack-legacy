"""Health check (AP-07) and the error envelope."""

from dataclasses import replace
from pathlib import Path

from fastapi.testclient import TestClient

from shiptrack.config import Settings
from shiptrack.main import create_app


def test_health_returns_ok_as_plain_text(client: TestClient) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert response.text == "OK"
    assert response.headers["content-type"].startswith("text/plain")


def test_health_is_green_while_the_database_is_unreachable(settings: Settings) -> None:
    """AP-07: the shallow health check hides a broken database."""
    broken = replace(settings, db_port=1, pod_dir=Path("/nonexistent"))
    with TestClient(create_app(broken), raise_server_exceptions=False) as client:
        assert client.get("/").status_code == 200
        response = client.get("/api/v1/shipments")
    assert response.status_code == 500
    assert response.json() == {
        "error": {"code": "INTERNAL", "message": "Internal server error", "request_id": None}
    }


def test_unknown_route_uses_the_envelope(client: TestClient) -> None:
    response = client.get("/api/v1/nope")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


def test_wrong_method_uses_the_envelope(client: TestClient) -> None:
    response = client.delete("/api/v1/shipments")
    assert response.status_code == 405
    assert set(response.json()["error"]) == {"code", "message", "request_id"}


def test_openapi_and_docs_are_not_exposed(client: TestClient) -> None:
    for path in ("/openapi.json", "/docs", "/redoc"):
        assert client.get(path).status_code == 404
