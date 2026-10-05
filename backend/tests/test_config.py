"""The run engine must only ever be pointed at the local Anvil chain."""

from __future__ import annotations

import pytest
from app.config import ALLOWED_RPC_HOSTS, LAB_CHAIN_ID, Settings
from pydantic import ValidationError

PUBLIC_RPC_ENDPOINTS = [
    "https://eth.llamarpc.com",
    "https://mainnet.infura.io/v3/abc123",
    "https://ethereum-rpc.publicnode.com",
]

NON_HTTP_RPC_ENDPOINTS = [
    "wss://rpc.ankr.com/eth",
    "ftp://anvil:8545",
    "file:///tmp/anvil.sock",
]


def _rpc_url(host: str) -> str:
    """Build a valid URL for a host, bracketing IPv6 literals."""
    formatted = f"[{host}]" if ":" in host else host
    return f"http://{formatted}:8545"


def test_defaults_pin_the_lab_chain() -> None:
    resolved = Settings(_env_file=None)  # type: ignore[call-arg]

    assert resolved.expected_chain_id == LAB_CHAIN_ID == 31337
    assert resolved.rpc_url == "http://anvil:8545"


def test_accepts_local_anvil_service() -> None:
    for host in sorted(ALLOWED_RPC_HOSTS):
        url = _rpc_url(host)
        assert Settings(rpc_url=url, _env_file=None).rpc_url == url  # type: ignore[call-arg]


@pytest.mark.parametrize("rpc_url", PUBLIC_RPC_ENDPOINTS)
def test_rejects_public_network_endpoints(rpc_url: str) -> None:
    with pytest.raises(ValidationError, match="not the local lab chain"):
        Settings(rpc_url=rpc_url, _env_file=None)  # type: ignore[call-arg]


@pytest.mark.parametrize("rpc_url", NON_HTTP_RPC_ENDPOINTS)
def test_rejects_non_http_schemes(rpc_url: str) -> None:
    with pytest.raises(ValidationError, match="must be http"):
        Settings(rpc_url=rpc_url, _env_file=None)  # type: ignore[call-arg]


def test_rejects_non_lab_chain_id() -> None:
    with pytest.raises(ValidationError, match="expected_chain_id must be 31337"):
        Settings(expected_chain_id=1, _env_file=None)  # type: ignore[call-arg]


def test_upload_limit_matches_prd() -> None:
    # FR-10 / PRD 6.2: .sol uploads are capped at 200 KB.
    assert Settings(_env_file=None).max_upload_bytes == 200 * 1024  # type: ignore[call-arg]
