"""Application settings.

Safety invariant: the run engine may only ever talk to the bundled local Anvil
chain. ``rpc_url`` comes from process configuration (never from an HTTP
request) and is validated against an allowlist of loopback/service hostnames.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from urllib.parse import urlparse

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

#: The only chain ChainGuard is allowed to attack or read from.
LAB_CHAIN_ID = 31337

#: Hostnames that may host the bundled local Anvil service.
ALLOWED_RPC_HOSTS = frozenset({"anvil", "localhost", "127.0.0.1", "::1"})


class Settings(BaseSettings):
    """Runtime configuration, loaded from the environment or a local `.env`."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "ChainGuard API"
    log_level: str = "INFO"
    cors_origins: list[str] = Field(default_factory=lambda: ["http://localhost:3000"])

    # --- local chain -------------------------------------------------------
    # Fixed to the internal `anvil` service. Never user-configurable.
    rpc_url: str = "http://anvil:8545"
    expected_chain_id: int = LAB_CHAIN_ID

    # --- datastores --------------------------------------------------------
    database_url: str = "postgresql+psycopg://chainguard:chainguard@localhost:5432/chainguard"
    redis_url: str = "redis://localhost:6379/0"

    # --- content -----------------------------------------------------------
    scenarios_dir: Path = Path("scenarios")
    explanations_dir: Path = Path("explanations")
    lab_state_dir: Path = Path("deployments")
    contracts_out_dir: Path = Path("../contracts/out")

    # --- analyzer ----------------------------------------------------------
    analysis_timeout_seconds: int = 60
    max_upload_bytes: int = 200 * 1024

    @field_validator("rpc_url")
    @classmethod
    def _only_local_lab_chain(cls, value: str) -> str:
        """Reject any RPC endpoint that is not the bundled local Anvil chain."""
        parsed = urlparse(value)
        if parsed.scheme not in {"http", "https"}:
            raise ValueError(f"rpc_url must be http(s), got {parsed.scheme!r}")
        host = parsed.hostname
        if host not in ALLOWED_RPC_HOSTS:
            raise ValueError(
                f"rpc_url host {host!r} is not the local lab chain "
                f"(allowed: {', '.join(sorted(ALLOWED_RPC_HOSTS))})"
            )
        return value

    @field_validator("expected_chain_id")
    @classmethod
    def _must_be_lab_chain_id(cls, value: int) -> int:
        if value != LAB_CHAIN_ID:
            raise ValueError(f"expected_chain_id must be {LAB_CHAIN_ID}, got {value}")
        return value


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the process-wide settings singleton."""
    return Settings()
