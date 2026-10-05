"""`GET /api/health` — chain, database and queue status."""

from __future__ import annotations

from fastapi import APIRouter

from app.config import get_settings
from app.engine.health import ChainStatus, ServiceStatus, probe_chain, probe_database, probe_redis
from app.schemas.health import ChainHealth, HealthResponse, ServiceHealth

router = APIRouter(tags=["health"])


def _as_chain_health(status: ChainStatus) -> ChainHealth:
    return ChainHealth(
        connected=status.connected,
        chain_id=status.chain_id,
        is_lab_chain=status.is_lab_chain,
    )


def _as_service_health(status: ServiceStatus) -> ServiceHealth:
    return ServiceHealth(connected=status.connected, detail=status.detail)


@router.get("/health", response_model=HealthResponse, summary="Service health")
def health() -> HealthResponse:
    """Report whether the lab chain, database and queue are reachable.

    The run engine refuses to execute unless `chain.is_lab_chain` is true, so
    this endpoint is also the operator's confirmation that attacks stay on the
    bundled local chain (chain ID 31337).
    """
    settings = get_settings()
    chain = _as_chain_health(probe_chain(settings))
    database = _as_service_health(probe_database(settings))
    redis = _as_service_health(probe_redis(settings))

    healthy = chain.connected and chain.is_lab_chain and database.connected and redis.connected
    return HealthResponse(
        status="ok" if healthy else "degraded",
        chain=chain,
        database=database,
        redis=redis,
    )
