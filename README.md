# ChainGuard

**Smart Contract Attack Simulator & Security Analyzer** — an educational security lab that runs real
attacks against deliberately vulnerable contracts on a **local, sandboxed Anvil chain (chain ID 31337)**,
then re-runs the identical attack against a hardened version to prove the fix works.

Every screen tells one story:

```
Attack → Transaction → State Change → Loss → Protection
```

> ⚠️ **Educational use only.** Nothing in this repository connects to mainnet or a public testnet.
> Uploaded Solidity is compiled and statically analyzed only — it is never deployed or executed.

## Tech stack

| Layer | Choice |
|-------|--------|
| Contracts | Solidity 0.8.24, OpenZeppelin v5, [Foundry](https://book.getfoundry.sh) |
| Local chain | Anvil (`anvil`, chain ID 31337) |
| Backend | FastAPI (Python 3.12), SQLAlchemy, Alembic, RQ + Redis |
| Frontend | Next.js 14 (App Router), TypeScript, Tailwind, shadcn/ui |
| Static analysis | Slither |
| Packaging | Docker Compose |

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) — `forge`, `anvil`, `cast`
- Node.js 20+ and npm
- [uv](https://docs.astral.sh/uv/) (Python 3.12)
- Docker + Docker Compose (optional — only needed for the full stack)

### 1. Install contract dependencies

```bash
cd contracts
forge install          # vendors forge-std + openzeppelin-contracts v5 into lib/
forge build
```

or from the repo root: `make deps`.

### 2. Run the contract tests

```bash
cd contracts
forge test
```

or from the repo root: `make test`.

### 3. Backend

```bash
cd backend
uv sync
uv run pytest
uv run uvicorn app.main:app --reload
```

### 4. Frontend

```bash
cd frontend
npm install
npm run dev
```

### 5. Full stack with Docker

```bash
docker compose up -d
```

Anvil is deliberately **not** published to the host or the internet — it is reachable only from the
other ChainGuard services over the internal Compose network.

## Makefile targets

| Target | Description |
|--------|-------------|
| `make deps` | Vendor Foundry libraries (`forge install`) |
| `make build` | Build contracts, backend and frontend |
| `make test` | Run the contract, backend and frontend test suites |
| `make up` | Start the full Docker Compose stack |
| `make down` | Tear the stack down |
| `make lint` | Run `forge fmt --check`, ruff, eslint and tsc |

## Repository layout

See [`specs/TDD.md`](specs/TDD.md) §2 for the authoritative layout. In short:

```
chainguard/
├── contracts/    # Foundry project — vulnerable + secure contracts and their tests
├── scenarios/    # YAML manifests, one per scenario
├── backend/      # FastAPI run engine, analyzer worker, reports
├── frontend/     # Next.js Lab UI, Analyzer, Proof Matrix
├── docker/       # Dockerfiles and the Compose entrypoint
└── specs/        # PRD, TDD and the step-by-step agent prompts
```

## Documentation

- [`specs/PRD.md`](specs/PRD.md) — product requirements
- [`specs/TDD.md`](specs/TDD.md) — technical design
- [`specs/AGENT_PROMPTS.md`](specs/AGENT_PROMPTS.md) — build order