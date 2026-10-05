# ChainGuard backend

FastAPI service that drives the local-chain attack engine and the static-analysis
worker.

## Safety invariants

- `RPC_URL` is process configuration, never an API parameter, and
  `app.config.Settings` rejects any host other than the bundled `anvil` service
  or loopback. `EXPECTED_CHAIN_ID` is pinned to `31337`.
- Uploaded Solidity is compiled and statically analyzed only. It is never
  deployed and never executed.

## Setup

```bash
uv sync
uv run pytest
uv run uvicorn app.main:app --reload
```

## Quality gates

```bash
uv run ruff check .
uv run ruff format --check .
uv run mypy app
```