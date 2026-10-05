"""Response schema for `GET /api/health`."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ChainHealth(BaseModel):
    """Status of the bundled local Anvil chain."""

    connected: bool
    chain_id: int | None = None
    is_lab_chain: bool = Field(
        default=False,
        description="True only when the node reports the lab chain ID (31337).",
    )


class ServiceHealth(BaseModel):
    """Status of an auxiliary dependency such as PostgreSQL or Redis."""

    connected: bool
    detail: str | None = None


class HealthResponse(BaseModel):
    """Aggregate service health."""

    status: Literal["ok", "degraded"]
    chain: ChainHealth
    database: ServiceHealth
    redis: ServiceHealth
