# ChainGuard — Technical Design Document (TDD)

**Related:** PRD.md
**Status:** Draft v1.0
**Last updated:** 2026-09-30

---

## 1. Architecture overview

```
                        ┌────────────────────────────┐
                        │  Frontend (Next.js + TS)   │
                        │  Lab · Analyzer · Matrix   │
                        └─────────────┬──────────────┘
                              REST + WebSocket
                        ┌─────────────▼──────────────┐
                        │   API (FastAPI, Python)    │
                        │  Run Engine · Job Queue    │
                        └──┬───────────┬─────────┬───┘
                           │           │         │
              JSON-RPC     │   enqueue │         │ SQL
                ┌──────────▼──┐  ┌─────▼─────┐ ┌─▼──────────┐
                │ Anvil (local│  │ Analyzer  │ │ PostgreSQL │
                │ chain 31337)│  │ Worker    │ └────────────┘
                └─────────────┘  │ (Slither, │
                                 │ solc,     │   Redis (queue +
                                 │ no network│   run events pub/sub)
                                 └───────────┘
```

### Key decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Contract framework | **Foundry** (primary), Hardhat (secondary workspace) | Fast Solidity-native tests, fuzzing, invariants, `anvil` built in |
| Local chain | **Anvil** | Snapshots, `debug_traceTransaction`, automine control |
| Backend | **FastAPI** (Python 3.12) | Slither is Python; async; easy JSON-RPC via `web3.py` |
| Queue | **RQ + Redis** | Simple, enough for analysis jobs |
| DB | **PostgreSQL** + SQLAlchemy + Alembic | Structured run/finding history |
| Frontend | **Next.js 14 (App Router)**, TypeScript, Tailwind, shadcn/ui | Standard, recruiter-recognizable |
| Graph | **React Flow** | Call-flow visualization |
| Code view | **Monaco Editor** (diff mode) | Side-by-side vulnerable vs. secure |
| Charts | **Recharts** | Balance timelines, severity bars |
| Packaging | **Docker Compose** | One-command startup |

## 2. Repository layout

```
chainguard/
├── contracts/                 # Foundry project
│   ├── foundry.toml
│   ├── lib/                   # forge-std, openzeppelin-contracts
│   ├── src/
│   │   ├── common/            # MockERC20, MockAMM, MockLender, MockOracle
│   │   └── scenarios/
│   │       ├── s1_reentrancy/{VulnerableVault.sol, SecureVault.sol, Attacker.sol}
│   │       ├── s2_access_control/...
│   │       ├── s3_logic/...
│   │       ├── s4_oracle/...
│   │       ├── s5_flashloan/...
│   │       ├── s6_frontrun/...
│   │       ├── s7_sig_replay/...
│   │       └── s8_unchecked_call/...
│   ├── script/DeployLab.s.sol # deploys everything, writes addresses JSON
│   └── test/
│       ├── scenarios/S1Reentrancy.t.sol ...
│       └── invariants/
├── hardhat/                   # optional TS mirror of scenario tests
├── scenarios/                 # manifests (YAML), one per scenario
├── backend/
│   ├── app/
│   │   ├── main.py
│   │   ├── config.py
│   │   ├── api/               # routers: scenarios, runs, analyses, health
│   │   ├── engine/            # chain client, run executor, trace parser
│   │   ├── analyzer/          # solc resolver, slither runner, normalizer, scoring
│   │   ├── reports/           # markdown + PDF renderers
│   │   ├── models/            # SQLAlchemy models
│   │   └── schemas/           # Pydantic
│   ├── worker/                # RQ worker entrypoint
│   ├── alembic/
│   └── tests/
├── frontend/
│   ├── app/                   # /, /lab, /lab/[id], /analyzer, /analyses/[id], /matrix
│   ├── components/            # FlowGraph, LossPanel, CodeDiff, SeverityBar, ScoreGauge
│   └── lib/api.ts
├── docker/                    # Dockerfiles (api, worker, analyzer-sandbox, anvil, web)
├── docker-compose.yml
└── .github/workflows/ci.yml
```

## 3. Contract layer

### 3.1 Conventions

- Solidity `0.8.24`, OpenZeppelin v5.
- Every scenario exposes the same shape so the engine can treat them generically:
  - `Vulnerable*` and `Secure*` share an interface (e.g., `IVault`).
  - `Attacker` takes the target address in its constructor and exposes `attack()` (payable where needed) and `profit()`.
- Common mocks in `src/common/` keep scenarios self-contained (no forking).

### 3.2 Scenario design notes

| ID | Victim | Attack mechanics (lab-only) | Expected: Vulnerable | Expected: Protected |
|----|--------|-----------------------------|----------------------|---------------------|
| S1 | `VulnerableVault` (ETH deposits) | Attacker's `receive()` re-enters `withdraw()` | Vault balance → 0 | Tx reverts (`ReentrancyGuardReentrantCall`) |
| S2 | `VulnerableWallet` with unprotected `setOwner` / `tx.origin` check | Attacker claims ownership, sweeps funds | Owner changed, funds moved | Reverts `OwnableUnauthorizedAccount` |
| S3 | `VulnerableToken` with `unchecked` balance math or rounding bug | Underflow/rounding yields inflated balance | Attacker balance > supply share | Revert on checked math; invariant holds |
| S4 | `VulnerableLending` reading `MockAMM` spot price | Skew AMM reserves, borrow against inflated collateral | Over-borrow succeeds | Oracle deviation check reverts |
| S5 | `VulnerableGovernance` using live token balance | Borrow tokens from `MockLender`, vote, repay in one tx | Proposal passes | Snapshot voting → 0 votes |
| S6 | `VulnerableQuiz` / swap with no slippage | Automine off; attacker tx with higher priority fee ordered first | Attacker wins / victim gets bad price | Commit-reveal / `minOut` + deadline revert |
| S7 | `VulnerableClaim` verifying ECDSA without nonce/domain | Resubmit a captured signature | Claim paid twice | Second claim reverts (nonce used) |
| S8 | `VulnerablePayout` ignoring `call` / `transfer` return | Recipient that rejects ETH / returns false | Accounting says paid, funds not sent | Reverts, `SafeERC20` enforces |

### 3.3 Deployment

`script/DeployLab.s.sol` deploys all scenario contracts (both variants), funds victims with deterministic amounts from Anvil default accounts, and writes `deployments/lab.json`:

```json
{
  "chainId": 31337,
  "s1_reentrancy": {
    "vulnerable": "0x…", "secure": "0x…",
    "attackerArtifact": "Attacker", "fundedWei": "10000000000000000000"
  }
}
```

After deployment the engine calls `evm_snapshot` and stores the base snapshot ID.

## 4. Scenario manifest

`scenarios/s1_reentrancy.yaml`

```yaml
id: s1_reentrancy
title: Reentrancy
severity: critical
swc: SWC-107
difficulty: beginner
real_world: "The DAO (2016)"
contracts:
  vulnerable: VulnerableVault
  secure: SecureVault
  attacker: Attacker
source_paths:
  vulnerable: contracts/src/scenarios/s1_reentrancy/VulnerableVault.sol
  secure: contracts/src/scenarios/s1_reentrancy/SecureVault.sol
  attacker: contracts/src/scenarios/s1_reentrancy/Attacker.sol
diff_highlight: { vulnerable: [18, 22], secure: [20, 24] }
steps:
  - action: deploy_attacker
    args: { target: "$TARGET" }
  - action: call
    contract: attacker
    fn: attack
    value_eth: 1
tracked_balances: [victim, attacker]
chain:
  automine: true
expected:
  vulnerable: { outcome: success, victim_balance_eth: 0 }
  secure: { outcome: reverted }
explanation_md: explanations/s1.md
```

A small DSL (`deploy_attacker`, `call`, `sign`, `mine`, `set_automine`, `send_raw`) covers all 8 scenarios. `$TARGET` resolves to the vulnerable or secure address depending on mode.

## 5. Backend

### 5.1 Chain client and safety guard

```python
class ChainClient:
    def __init__(self, rpc_url: str):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        if self.w3.eth.chain_id != 31337:
            raise RuntimeError("ChainGuard only runs against the local lab chain")
```

- RPC URL is fixed via config to the internal `anvil` service; it is not user-supplied.
- Attacker contracts are deployed only by the engine; target addresses must be present in `lab.json`.

### 5.2 Run executor

```
POST /runs {scenario_id, mode}
  → lock (one run at a time on the chain; Redis lock)
  → evm_revert(base_snapshot); new snapshot
  → read balances (before)
  → execute manifest steps, collect tx hashes
  → for each tx: receipt + debug_traceTransaction(callTracer)
  → read balances (after)
  → parse trace → CallNode tree → flow graph JSON
  → compare against manifest.expected → verdict
  → persist Run + RunSteps; publish events on WS
  → release lock
```

Runs are short, so a single global lock is fine for v1. v2 can pool several Anvil instances.

### 5.3 Trace parser

Input: Geth `callTracer` output. Output:

```json
{
  "nodes": [
    {"id": "0", "label": "Attacker.attack()", "from": "0xA…", "to": "0xB…", "value": "1e18", "status": "ok", "depth": 0},
    {"id": "1", "label": "Vault.withdraw()", "depth": 1},
    {"id": "2", "label": "Attacker.receive()", "depth": 2}
  ],
  "edges": [{"source": "0", "target": "1"}, {"source": "1", "target": "2"}],
  "summary": {"reentrancy_depth": 10, "reverted": false, "revert_reason": null}
}
```

- Function selectors decoded with ABIs from `contracts/out/`.
- Custom errors decoded from revert data.
- Frames to known library addresses collapsed.
- Repeated identical frames beyond depth 12 collapsed into "× N more".

### 5.4 Analyzer pipeline

```
POST /analyses (multipart or JSON source)
  → validate: size ≤ 200 KB, .sol, UTF-8
  → persist job (queued) → enqueue RQ task
Worker (sandbox container: no network, 1 CPU, 1 GB RAM, 60 s timeout):
  → write to tmp workspace
  → parse pragma → pick solc via solc-select (pre-installed versions only)
  → remappings: @openzeppelin/=lib/openzeppelin-contracts/
  → slither <file> --json - --solc-remaps ...
  → normalize detectors → Finding[]
  → score + grade
  → persist, status=done
```

Uploaded code is **never deployed or executed**; it is only compiled and statically analyzed.

**Severity normalization**

```python
OVERRIDES = {
    "reentrancy-eth": "critical",
    "arbitrary-send-eth": "critical",
    "suicidal": "critical",
    "unprotected-upgrade": "critical",
    "controlled-delegatecall": "high",
    "unchecked-lowlevel": "high",
    "unchecked-transfer": "high",
    "tx-origin": "medium",
    "reentrancy-no-eth": "medium",
}
IMPACT_MAP = {"High": "high", "Medium": "medium", "Low": "low", "Informational": "info", "Optimization": "info"}
```

Low-confidence findings are downgraded one level.

**Remediation text** lives in `analyzer/remediations.yaml` keyed by detector name.

### 5.5 Data model

```
scenarios(id PK, title, severity, swc, difficulty, manifest JSONB)
runs(id UUID PK, scenario_id FK, mode ENUM(vulnerable,secure),
     verdict ENUM(pass,fail,error), outcome ENUM(success,reverted),
     victim_before, victim_after, attacker_before, attacker_after NUMERIC(78,0),
     gas_used BIGINT, flow_graph JSONB, created_at, duration_ms)
run_steps(id PK, run_id FK, idx, tx_hash, status, revert_reason, gas_used, trace JSONB)
analyses(id UUID PK, filename, source_sha256, solc_version,
         status ENUM(queued,compiling,analyzing,done,failed),
         score INT, grade CHAR(1), counts JSONB, error TEXT, created_at, duration_ms)
findings(id PK, analysis_id FK, detector, severity, confidence,
         title, description, lines INT[], remediation TEXT)
```

### 5.6 API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Chain, DB, Redis status |
| GET | `/api/scenarios` | List scenarios |
| GET | `/api/scenarios/{id}` | Manifest + source code + explanation |
| POST | `/api/runs` | `{scenario_id, mode}` → `{run_id}` |
| GET | `/api/runs/{id}` | Full run result |
| GET | `/api/runs?scenario=&mode=` | History |
| WS | `/api/runs/{id}/events` | `step_started`, `tx_mined`, `trace_ready`, `done` |
| POST | `/api/analyses` | Upload/paste → `{analysis_id}` |
| GET | `/api/analyses/{id}` | Status + findings |
| GET | `/api/analyses/{id}/report.{md,pdf}` | Export |
| GET | `/api/matrix` | Latest verdict per scenario × mode |

Rate limits (slowapi): runs 20/min/IP, analyses 5/min/IP.

## 6. Frontend

### Pages

- `/` — landing with pitch, GIF, stack badges.
- `/lab` — scenario grid (card: title, severity chip, difficulty).
- `/lab/[id]` — main scenario view.
- `/analyzer` — upload/paste.
- `/analyses/[id]` — report.
- `/matrix` — proof matrix.

### Scenario view layout

```
┌───────────────────────────────┬──────────────────────────────┐
│ Code tabs: Vuln | Secure |    │ Mode: [Vulnerable|Protected] │
│ Attacker | Diff (Monaco)      │ [Run Attack] [Step ▶]        │
│                               ├──────────────────────────────┤
│                               │ FlowGraph (React Flow)       │
├───────────────────────────────┼──────────────────────────────┤
│ Explanation (markdown)        │ LossPanel · Tx table         │
└───────────────────────────────┴──────────────────────────────┘
```

- `FlowGraph` animates nodes sequentially on `trace_ready`; reverted frames red, success green.
- Step mode reveals one node per click and highlights the matching source line (via source maps from `forge build --extra-output`), if available; otherwise function-level highlight.
- `LossPanel`: before/after bars, stolen amount, "Funds SAFE" state for protected runs.

## 7. Testing strategy

| Layer | Tooling | What is covered |
|-------|---------|-----------------|
| Contracts | `forge test` | For each scenario: `test_exploit_succeeds_on_vulnerable`, `test_exploit_fails_on_secure` |
| Contracts | Fuzz | Deposit/withdraw amounts, signature inputs, oracle prices |
| Contracts | Invariants | e.g., `sum(balances) == address(vault).balance` for SecureVault |
| Contracts | `forge coverage` | ≥ 90% lines on `src/scenarios` |
| Contracts | Slither | Secure contracts: zero Critical/High; vulnerable contracts: expected detectors fire (golden file) |
| Backend | pytest + testcontainers (Anvil, Postgres, Redis) | Run executor, trace parser (fixture traces), scoring, API |
| Frontend | Vitest + Testing Library | Components |
| E2E | Playwright | Run S1 vulnerable → drained; protected → safe; analyzer upload happy path |
| Hardhat | Mocha/Chai (TS) | Mirror of S1, S2, S8 |

## 8. CI/CD (GitHub Actions)

```
jobs:
  contracts:  forge fmt --check · forge build · forge test -vvv · forge coverage · slither (secure only, fail on high)
  backend:    ruff · mypy · pytest
  frontend:   eslint · tsc · vitest · next build
  e2e:        docker compose up -d · playwright test
  matrix:     export verdicts JSON → artifact → consumed by /api/matrix seed
  deploy:     (main only) build images → push → deploy (Fly.io / Railway / VPS)
```

## 9. Security considerations

- **Local chain only:** chain ID assertion at startup; RPC not user-configurable; Anvil not exposed publicly (internal Docker network only).
- **Analyzer sandbox:** separate container, `network_mode: none`, read-only root FS, tmpfs workspace, non-root user, hard timeout, no `ffi`, no execution of user code.
- **Input limits:** file size, file count = 1, extension check, UTF-8 only.
- **Rate limiting** and request size caps at the API.
- **Secrets:** none required beyond DB credentials; Anvil keys are public test keys.
- **Content:** lab contracts target only mock contracts inside the lab; the README states the educational purpose.

## 10. Deployment

- `docker-compose.yml` services: `web`, `api`, `worker`, `anvil`, `postgres`, `redis`.
- `anvil` starts, then a one-shot `deployer` runs `forge script DeployLab` and writes `lab.json` to a shared volume; `api` waits for it.
- Single VPS (2 vCPU / 4 GB) is enough for a demo.

## 11. Performance targets

| Operation | Target |
|-----------|--------|
| Snapshot revert | < 50 ms |
| Scenario run (incl. traces) | < 10 s p95 |
| Slither analysis | < 60 s p95 |
| Page LCP | < 2.5 s |

## 12. Future work

- Multiple Anvil workers for concurrent runs.
- Aderyn/Mythril as additional analyzers with merged findings.
- AI-generated plain-English explanations of findings.
- User-authored scenarios (manifest editor).
