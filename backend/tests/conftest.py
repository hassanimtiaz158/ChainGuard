"""Shared pytest fixtures.

Tests never read a developer's local `.env`, so settings always come from
defaults unless a test explicitly overrides values.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from app.config import Settings
from app.main import create_app
from fastapi.testclient import TestClient


@pytest.fixture
def settings() -> Settings:
    """Settings built from defaults only (ignores any local `.env`)."""
    return Settings(_env_file=None)  # type: ignore[call-arg]


@pytest.fixture
def client() -> Iterator[TestClient]:
    """A TestClient bound to the real application."""
    with TestClient(create_app()) as test_client:
        yield test_client
