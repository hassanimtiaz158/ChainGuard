"""Health probes for the local chain, the database and the job queue.

These are deliberately shallow: short timeouts, no retries, and every failure is
converted into a status object rather than an exception.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from functools import lru_cache

import httpx
from redis import Redis
from redis.exceptions import RedisError
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.exc import SQLAlchemyError

from app.config import Settings, get_settings

logger = logging.getLogger(__name__)

PROBE_TIMEOUT_SECONDS = 2.0


@dataclass(frozen=True, slots=True)
class ChainStatus:
    """Result of probing `eth_chainId` on the local Anvil node."""

    connected: bool
    chain_id: int | None
    is_lab_chain: bool


@dataclass(frozen=True, slots=True)
class ServiceStatus:
    """Result of probing an auxiliary service."""

    connected: bool
    detail: str | None = None


def probe_chain(settings: Settings) -> ChainStatus:
    """Ask the local node for its chain ID."""
    payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}
    try:
        response = httpx.post(settings.rpc_url, json=payload, timeout=PROBE_TIMEOUT_SECONDS)
        response.raise_for_status()
        raw_result = response.json().get("result")
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("chain probe failed: %s", exc)
        return ChainStatus(connected=False, chain_id=None, is_lab_chain=False)

    if not isinstance(raw_result, str):
        logger.warning("chain probe returned no result: %r", raw_result)
        return ChainStatus(connected=False, chain_id=None, is_lab_chain=False)

    chain_id = int(raw_result, 16)
    return ChainStatus(
        connected=True,
        chain_id=chain_id,
        is_lab_chain=chain_id == settings.expected_chain_id,
    )


@lru_cache(maxsize=2)
def _sqlalchemy_engine(database_url: str) -> Engine:
    return create_engine(database_url, pool_pre_ping=True)


@lru_cache(maxsize=2)
def _redis_client(redis_url: str) -> Redis:
    return Redis.from_url(
        redis_url,
        socket_connect_timeout=PROBE_TIMEOUT_SECONDS,
        socket_timeout=PROBE_TIMEOUT_SECONDS,
    )


def probe_database(settings: Settings) -> ServiceStatus:
    """Run a trivial statement against the configured database."""
    try:
        with _sqlalchemy_engine(settings.database_url).connect() as connection:
            connection.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        return ServiceStatus(connected=False, detail=str(exc).splitlines()[0][:200])
    return ServiceStatus(connected=True)


def probe_redis(settings: Settings) -> ServiceStatus:
    """Ping the job queue broker."""
    try:
        _redis_client(settings.redis_url).ping()
    except RedisError as exc:
        return ServiceStatus(connected=False, detail=str(exc)[:200])
    return ServiceStatus(connected=True)


def collect_health(
    settings: Settings | None = None,
) -> tuple[ChainStatus, ServiceStatus, ServiceStatus]:
    """Probe the chain, database and queue in one call."""
    resolved = settings or get_settings()
    return probe_chain(resolved), probe_database(resolved), probe_redis(resolved)
