"""`GET /api/health` contract tests (specs/TDD.md 5.6)."""

from __future__ import annotations

from app.config import LAB_CHAIN_ID
from fastapi.testclient import TestClient


def test_health_returns_200_with_expected_shape(client: TestClient) -> None:
    response = client.get("/api/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] in {"ok", "degraded"}
    assert set(body["chain"]) == {"connected", "chain_id", "is_lab_chain"}
    assert set(body["database"]) == {"connected", "detail"}
    assert set(body["redis"]) == {"connected", "detail"}


def test_health_is_degraded_when_no_local_chain_is_running(client: TestClient) -> None:
    body = client.get("/api/health").json()

    if not body["chain"]["connected"]:
        # The only acceptable outcome outside Docker: the chain is simply absent.
        assert body["status"] == "degraded"
        assert body["chain"]["chain_id"] is None
        assert body["chain"]["is_lab_chain"] is False
    else:
        # If a node answered, it must be the lab chain -- never another network.
        assert body["chain"]["chain_id"] == LAB_CHAIN_ID
        assert body["chain"]["is_lab_chain"] is True


def test_openapi_document_is_served(client: TestClient) -> None:
    response = client.get("/openapi.json")

    assert response.status_code == 200
    assert "/api/health" in response.json()["paths"]
