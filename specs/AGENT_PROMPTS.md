# ChainGuard — Step-by-Step Prompts for an AI Coding Agent

Use these in order with Claude Code, Cursor, or a similar agent. Put `PRD.md` and `TDD.md` in the repo root first so the agent can read them. Run one prompt at a time, review the diff, run the tests, commit, then move on.

---

## Prompt 0 — Project context (paste once at the start of every session)

```
You are building ChainGuard, an educational smart contract security lab.
Read PRD.md and TDD.md in the repo root before doing anything. They are the source of truth.

Hard rules:
- All attack scenarios run ONLY on the bundled local Anvil chain (chain ID 31337). Never add
  code that connects to mainnet or public testnets, and never make the RPC URL user-configurable.
- Attacker contracts only target the lab's own vulnerable contracts.
- Uploaded Solidity is compiled and statically analyzed only — never deployed or executed.
- Solidity 0.8.24, OpenZeppelin v5, Foundry primary.
- Follow the repo layout in TDD.md §2 exactly.
- After every task: run the relevant tests, show me the results, and list files changed.
- Don't move on to the next step unless I ask.
```

---

## Prompt 1 — Monorepo scaffold

```
Create the monorepo skeleton from TDD.md §2:
- contracts/ as a Foundry project (forge init --no-git), install forge-std and
  openzeppelin-contracts v5, add remappings.
- backend/ with FastAPI, pyproject.toml (uv or poetry), ruff, mypy, pytest configured.
- frontend/ with Next.js 14 App Router, TypeScript, Tailwind, shadcn/ui, ESLint.
- docker/ with placeholder Dockerfiles, docker-compose.yml with services
  web, api, worker, anvil, postgres, redis (internal network; anvil NOT exposed publicly).
- .github/workflows/ci.yml with empty jobs: contracts, backend, frontend.
- Root README.md with project title and a "Getting started" section.
- Makefile with targets: build, test, up, down, lint.

Acceptance: `forge build` succeeds, `pytest` runs (0 tests OK), `npm run build` succeeds,
`docker compose config` validates.
```

---

## Prompt 2 — Common mocks

```
In contracts/src/common/ create:
- MockERC20 (mintable, OpenZeppelin ERC20)
- MockNonStandardERC20 (transfer returns false instead of reverting) for S8
- MockAMM: constant-product pool for two MockERC20s with swap() and getSpotPrice()
- MockLender: flash loan of MockERC20 with a callback interface and fee = 0
- MockTWAPOracle: returns a time-weighted price, with updatedAt for staleness checks
Add unit tests for each in contracts/test/common/.

Acceptance: forge test passes, forge coverage ≥ 90% on src/common.
```

---

## Prompt 3 — Scenario S1 (Reentrancy)

```
Implement scenario S1 per TDD.md §3.2 in contracts/src/scenarios/s1_reentrancy/:
- IVault interface (deposit, withdraw, balanceOf)
- VulnerableVault: sends ETH before updating the balance
- SecureVault: Checks-Effects-Interactions + OpenZeppelin ReentrancyGuard
- Attacker: constructor(target), attack() payable deposits then withdraws,
  receive() re-enters while target has balance, profit() view
Add NatSpec comments explaining the bug and fix on the relevant lines.

Tests in contracts/test/scenarios/S1Reentrancy.t.sol:
- test_exploit_succeeds_on_vulnerable: victim funded with 10 ETH by 3 users, attacker
  drains it, assert vault balance == 0 and attacker profit > 0
- test_exploit_fails_on_secure: same setup, expect revert with ReentrancyGuardReentrantCall
- fuzz test for normal deposit/withdraw on SecureVault
- invariant: sum of user balances == address(vault).balance for SecureVault

Also create scenarios/s1_reentrancy.yaml and explanations/s1.md per TDD.md §4.
```

---

## Prompt 4 — Scenarios S2 and S8

```
Implement S2 (access control) and S8 (unchecked external call) following the same
pattern as S1: interface, Vulnerable*, Secure*, Attacker (or helper recipient),
Foundry tests (exploit succeeds on vulnerable, fails on secure), YAML manifest,
and explanation markdown.

S2: vulnerable uses an unprotected setOwner and a tx.origin check; secure uses Ownable.
S8: vulnerable ignores the bool from low-level call and from MockNonStandardERC20.transfer;
secure checks return values and uses SafeERC20.

Acceptance: all tests pass; forge coverage on these scenarios ≥ 90%.
```

---

## Prompt 5 — Scenarios S3, S4

```
Implement S3 (integer/logic) and S4 (oracle manipulation) with the same pattern.

S3: vulnerable token performs balance subtraction inside an `unchecked` block, plus a
rounding-order bug in a reward calculation (divide before multiply). Secure version
uses checked math and multiply-before-divide. Include an invariant test that total
balances never exceed totalSupply.

S4: VulnerableLending prices collateral using MockAMM.getSpotPrice(). The attacker
skews reserves with a large swap, borrows against inflated collateral, swaps back.
SecureLending uses MockTWAPOracle with staleness and max-deviation checks versus spot,
reverting with a custom error when deviation is too high.

Acceptance: tests pass; S4 test logs collateral value before/after manipulation.
```

---

## Prompt 6 — Scenarios S5, S6, S7

```
Implement S5, S6, S7 with the same pattern.

S5: VulnerableGovernance counts votes by current token balance. Attacker uses
MockLender flash loan inside one tx to vote and repay. SecureGovernance uses
OpenZeppelin ERC20Votes checkpoints / snapshot block, so flash-borrowed tokens give 0 votes.

S6: VulnerableQuiz pays a prize to the first correct plaintext answer submitted.
SecureQuiz uses commit-reveal (commit hash with salt, reveal after N blocks).
Also add a swap example in MockAMM usage: vulnerable call with no minOut/deadline,
secure call with minOut + deadline. Foundry test uses vm.prank ordering to model
the attacker's transaction landing first.

S7: VulnerableClaim verifies an ECDSA signature over (to, amount) only.
SecureClaim uses EIP-712 with nonces, chainId, and verifying contract (OpenZeppelin
EIP712 + Nonces). Test replays the same signature twice.

Acceptance: all 8 scenarios' tests pass with `forge test`.
```

---

## Prompt 7 — Deploy script and Slither golden tests

```
1. Create contracts/script/DeployLab.s.sol that deploys every scenario (vulnerable
   and secure), funds victims deterministically from Anvil default accounts, and
   writes deployments/lab.json in the format from TDD.md §3.3.
2. Add a `deployer` one-shot service to docker-compose that waits for anvil, runs the
   script, and writes lab.json to a shared volume.
3. Add contracts/slither.config.json and a script scripts/slither_check.sh that:
   - runs Slither on all Secure* contracts and fails if any High/Critical finding exists
   - runs Slither on all Vulnerable* contracts and compares detector names against
     contracts/test/slither_golden.json (expected detectors per scenario)
Wire both into the CI `contracts` job.
```

---

## Prompt 8 — Backend foundation

```
In backend/, implement per TDD.md §5:
- config.py with pydantic-settings (RPC_URL fixed to http://anvil:8545 by default,
  DATABASE_URL, REDIS_URL)
- SQLAlchemy models and Alembic migration for tables in TDD.md §5.5
- ChainClient with the chain ID 31337 guard (raise on anything else) and helpers:
  snapshot(), revert(id), set_automine(bool), mine(), get_balance(), trace_tx(hash)
  using debug_traceTransaction with callTracer
- Scenario loader that reads scenarios/*.yaml and lab.json, validates with Pydantic
- GET /api/health, GET /api/scenarios, GET /api/scenarios/{id} (includes source code
  and explanation markdown)
Tests with pytest + testcontainers (Anvil + Postgres). Include a test proving the
ChainClient refuses a non-31337 chain.
```

---

## Prompt 9 — Run engine and trace parser

```
Implement the run executor and trace parser per TDD.md §5.2–5.3:
- Manifest step DSL: deploy_attacker, call, sign, mine, set_automine, send_raw
- Redis lock so only one run uses the chain at a time
- Revert to base snapshot before each run
- Collect receipts, traces, before/after balances, events
- Trace parser: decode selectors and custom errors using ABIs from contracts/out/,
  collapse library frames and repeated frames past depth 12, output nodes/edges/summary
- Verdict: compare result to manifest.expected
- POST /api/runs, GET /api/runs/{id}, GET /api/runs (filters), WS /api/runs/{id}/events
Save fixture traces for S1 vulnerable and secure under backend/tests/fixtures and
unit-test the parser against them. Integration test: run all 16 scenario×mode
combinations and assert every verdict == pass.
```

---

## Prompt 10 — Analyzer worker

```
Implement the analyzer per TDD.md §5.4:
- POST /api/analyses accepts multipart file or JSON {source}; validate size ≤ 200 KB,
  .sol extension, UTF-8
- RQ task: write to tmp dir, detect pragma, choose a pre-installed solc via solc-select,
  run slither with OpenZeppelin remappings and --json output, normalize with the
  OVERRIDES and IMPACT_MAP from TDD.md, downgrade low-confidence findings,
  attach remediation from analyzer/remediations.yaml, compute score and grade (PRD §8)
- Status transitions: queued → compiling → analyzing → done | failed (with error text)
- docker/analyzer-sandbox.Dockerfile: slither + solc versions 0.8.20–0.8.26 preinstalled,
  non-root user; compose service with network_mode: none, read-only root FS,
  tmpfs workspace, 1 CPU, 1 GB RAM; worker enforces a 60 s timeout
- GET /api/analyses/{id}, GET /api/analyses/{id}/report.md and report.pdf
  (PDF via WeasyPrint from an HTML template)
- Rate limits via slowapi (runs 20/min, analyses 5/min per IP)
Tests: scoring unit tests; analyze each Vulnerable* contract and assert the expected
detectors fire; a malformed contract yields status=failed with a readable error.
```

---

## Prompt 11 — Frontend: Lab

```
Build the frontend Lab per TDD.md §6:
- lib/api.ts typed client (generate types from the FastAPI OpenAPI schema)
- /lab: scenario grid with severity chip and difficulty
- /lab/[id]: layout from TDD.md §6
  - Monaco editor tabs: Vulnerable, Secure, Attacker, Diff (diff editor with highlight
    ranges from the manifest)
  - Mode toggle (Vulnerable / Protected), Run Attack button, Step button
  - FlowGraph with React Flow: vertical layout (dagre), nodes animate in order,
    reverted frames red, success green, final node "Contract drained" or "Funds SAFE"
  - LossPanel: before/after bar chart (Recharts), stolen amount, attacker profit
  - Tx table: hash, status, gas, revert reason
  - Explanation panel rendering markdown
- Subscribe to the run WebSocket for live progress
- Accessible text alternative for the graph (collapsible table of frames)
Design: dark theme, security aesthetic, clean typography. Vitest tests for FlowGraph
and LossPanel.
```

---

## Prompt 12 — Frontend: Analyzer, Matrix, Landing

```
Build:
- /analyzer: drag-and-drop upload + paste tab (Monaco), submit, poll status with a
  stepper (queued → compiling → analyzing → done)
- /analyses/[id]: ScoreGauge (0–100 + grade), SeverityBar (Critical/High/Medium/Low/Info
  counts), findings list grouped by severity with line highlighting in a read-only
  Monaco view, remediation text, export buttons (MD, PDF)
- /matrix: 8×2 grid of pass/fail badges from GET /api/matrix
- /: landing with one-line pitch, embedded demo GIF placeholder, tech stack badges
  (Solidity, EVM, Foundry, Hardhat, OpenZeppelin, Slither, FastAPI, Next.js, Docker),
  "Try the Lab" and "Scan a Contract" CTAs
Playwright E2E: run S1 vulnerable → "Contract drained"; protected → "Funds SAFE";
upload a sample vulnerable contract → report shows ≥ 1 Critical.
```

---

## Prompt 13 — Hardhat mirror

```
Create hardhat/ as a TypeScript Hardhat project that compiles the same contracts
(point sources at ../contracts/src, use OpenZeppelin from node_modules) and mirrors
the S1, S2, and S8 tests in Mocha/Chai with ethers v6. Add hardhat-gas-reporter.
Add a `hardhat` job to CI. Acceptance: `npx hardhat test` passes.
```

---

## Prompt 14 — CI/CD completion

```
Complete .github/workflows/ci.yml per TDD.md §8:
- contracts: forge fmt --check, build, test -vvv, coverage (upload lcov), slither_check.sh
- backend: ruff, mypy, pytest (with services)
- frontend: eslint, tsc --noEmit, vitest, next build
- e2e: docker compose up -d --wait, playwright test, upload report on failure
- matrix: export scenario verdicts JSON as an artifact
- deploy (main only): build and push images to GHCR
Add status badges to README.
```

---

## Prompt 15 — Polish, docs, demo

```
Final polish:
- README: pitch, architecture diagram (Mermaid), screenshots/GIF placeholders,
  scenario table, "How the attack engine stays safe" section (local chain only,
  sandboxed analyzer), local setup, test commands, tech stack, roadmap
- docs/SCENARIOS.md: for each scenario, the root cause, real-world incident, and fix
- Seed demo data so the dashboard has recent runs on first boot
- Check Lighthouse on /lab/s1_reentrancy (aim ≥ 90 performance and accessibility)
- Review all code for TODOs, dead code, and missing tests; list anything remaining.
```

---

### Tips for working with the agent

- If a step fails, paste the exact error back and say "fix only this; don't refactor other files."
- Commit after every prompt so you can roll back easily.
- Ship S1 fully end-to-end (contract → backend → UI) before building the other seven if you want a demo early.
