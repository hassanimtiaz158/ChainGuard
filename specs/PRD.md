# ChainGuard — Product Requirements Document (PRD)

**Product:** ChainGuard — Smart Contract Attack Simulator & Security Analyzer
**Owner:** Zohaib (Echolyx)
**Status:** Draft v1.0
**Type:** Portfolio / educational security platform
**Last updated:** 2026-09-30

---

## 1. Summary

ChainGuard is a web platform that teaches and demonstrates smart contract security by running real attacks against deliberately vulnerable contracts on a **local, sandboxed EVM chain**, then re-running the same attack against a hardened version to prove the fix works. It also lets users upload their own Solidity contracts and get a static-analysis security report (powered by Slither) with a severity breakdown and a security score.

The core story every screen tells:

```
Attack → Transaction → State Change → Loss → Protection
```

## 2. Problem

- Smart contract vulnerabilities are usually taught through static text and code snippets. Learners rarely *see* a call stack re-enter a function or watch a balance drain in real time.
- Existing labs (Ethernaut, Damn Vulnerable DeFi) are excellent for puzzles but don't show a side-by-side "vulnerable vs. protected" comparison with visualized traces.
- Developers who want a quick sanity check on their contract have to install and configure Slither locally and interpret raw detector output.

## 3. Goals

| # | Goal | Measure of success |
|---|------|--------------------|
| G1 | Visually demonstrate 8 classic vulnerability classes | Each scenario runs end-to-end in < 10 s and renders a call-flow graph |
| G2 | Prove each mitigation works | Every scenario has a "Protected" mode where the same attack reverts or yields zero profit |
| G3 | Provide a useful static analysis report | Upload → report in < 60 s for contracts under 1,000 lines |
| G4 | Showcase professional engineering | CI with Foundry tests, fuzz/invariant tests, Slither gate, Docker deploy, public demo |

### Non-goals

- Analyzing or attacking contracts deployed on any public network (mainnet or public testnets).
- Formal verification or a full audit replacement.
- Custody of real funds, wallets, or private keys belonging to users.
- Multi-chain support beyond the EVM in v1.

## 4. Target users

1. **Recruiters / hiring managers** (primary for portfolio purposes) — need to grasp the project in 60 seconds via a live demo.
2. **Solidity learners** — want to understand *why* an attack works by stepping through it.
3. **Junior Solidity developers** — want a quick first-pass scan of their contract.

## 5. User stories

- As a learner, I pick "Reentrancy" and click **Run Attack**, and I see the attacker's contract re-entering `withdraw()` repeatedly until the vault is empty.
- As a learner, I toggle **Protection: ON** and re-run; I see the transaction revert and the vault balance unchanged.
- As a learner, I see the vulnerable and secure code side by side with the exact changed lines highlighted.
- As a learner, I can step through the attack one call at a time and see storage/balance changes at each step.
- As a developer, I upload a `.sol` file (or paste code) and receive a security score plus findings grouped by severity, each with a line reference, explanation, and recommended fix.
- As a developer, I download the report as Markdown or PDF.
- As a recruiter, I open the landing page and understand the tech stack and a live demo within one minute.

## 6. Functional requirements

### 6.1 Attack Lab (scenarios)

Each scenario ships with: a vulnerable contract, a secure contract, an attacker contract/script, a manifest (title, description, severity, CWE/SWC reference, expected outcome), and Foundry tests.

| ID | Scenario | Vulnerable pattern | Protection shown |
|----|----------|--------------------|------------------|
| S1 | Reentrancy | External call before state update | Checks-Effects-Interactions + OpenZeppelin `ReentrancyGuard` |
| S2 | Access-control failure | Unprotected privileged function / `tx.origin` auth | `Ownable` / `AccessControl`, `msg.sender` checks |
| S3 | Integer / logic error | Arithmetic inside `unchecked` block; rounding/precision bug | Checked math, correct ordering of operations, invariant tests |
| S4 | Oracle manipulation | Price read from a single AMM spot reserve | TWAP / mock aggregated oracle with staleness + deviation checks |
| S5 | Flash-loan-style attack | Governance/price logic that trusts same-block balances | Snapshot-based voting / time-weighted values |
| S6 | Front-running | Public reveal of a valuable answer / unbounded slippage | Commit-reveal scheme / slippage & deadline parameters |
| S7 | Signature replay | Signed message without nonce, chainId, or contract address | EIP-712 typed data with nonces and domain separator |
| S8 | Unchecked external call | Ignored return value of low-level `call` / non-standard ERC-20 `transfer` | Return-value checks, `SafeERC20` |

**Requirements**

- FR-1: User can list scenarios with difficulty, severity, and a short description.
- FR-2: User can run any scenario in **Vulnerable** or **Protected** mode.
- FR-3: Every run executes on a fresh chain state (no leakage between runs).
- FR-4: Run results include: tx hashes, status (success/reverted), revert reason, gas used, call tree, balance deltas for victim and attacker, and events emitted.
- FR-5: Result view renders the call tree as a flow graph (e.g., `Attacker → withdraw() → fallback → withdraw() → … → drained`).
- FR-6: Step-through mode lets the user advance one call frame at a time.
- FR-7: Side-by-side diff of vulnerable vs. secure source with highlighted lines.
- FR-8: Loss panel shows funds before/after, amount stolen, and attacker profit.
- FR-9: "Explain" panel describes root cause, real-world incident reference (e.g., The DAO for reentrancy), and fix.

### 6.2 Contract Analyzer

- FR-10: Upload a `.sol` file (≤ 200 KB) or paste source.
- FR-11: Detect the pragma version and select a matching `solc` automatically.
- FR-12: Support imports of OpenZeppelin contracts via preconfigured remappings; other external imports return a clear error.
- FR-13: Run Slither and normalize findings to Critical / High / Medium / Low / Informational.
- FR-14: Compute a Security Score (0–100) and letter grade.
- FR-15: Each finding shows detector name, severity, confidence, affected lines, description, and remediation.
- FR-16: Report exportable as Markdown and PDF.
- FR-17: Analysis jobs are asynchronous with progress status (queued → compiling → analyzing → done/failed).

### 6.3 Dashboard

- FR-18: Home dashboard shows scenario cards, recent runs, and recent analyses.
- FR-19: Run history with filters (scenario, mode, outcome).
- FR-20: A "Protection Proof" matrix: all 8 scenarios × {Vulnerable, Protected} with pass/fail badges pulled from the latest CI run.

### 6.4 Developer / DevSecOps

- FR-21: Foundry test suite proves each exploit succeeds against the vulnerable contract and fails against the secure one.
- FR-22: Fuzz and invariant tests for secure contracts.
- FR-23: CI pipeline runs Foundry tests, coverage, Slither on secure contracts (must report zero High/Critical), backend tests, frontend lint, and E2E tests.
- FR-24: Optional Hardhat workspace that runs the same scenarios in TypeScript tests to demonstrate tool familiarity.

## 7. Non-functional requirements

| Area | Requirement |
|------|-------------|
| Safety | The attack engine connects **only** to the bundled local chain (chain ID 31337). Any other RPC/chain ID is refused at startup. Attacker contracts only target lab contracts deployed by ChainGuard. |
| Sandboxing | Uploaded code is compiled and analyzed only (never deployed or executed) inside a container with no network access, CPU/memory limits, and a 60 s timeout. |
| Performance | Scenario run < 10 s; analysis < 60 s for typical contracts. |
| Reliability | Chain state reset via snapshot/revert after every run. |
| Security | Rate limiting on upload and run endpoints; input size limits; no user secrets stored. |
| Accessibility | Graphs have a text/table alternative; keyboard navigation. |
| Observability | Structured logs, request IDs, job durations. |
| Portability | Whole stack starts with `docker compose up`. |

## 8. Security scoring model (v1)

```
score = max(0, 100 − (25 × Critical + 10 × High + 4 × Medium + 1 × Low))
Grade: A ≥ 90, B ≥ 75, C ≥ 60, D ≥ 40, F < 40
Any Critical caps the grade at D.
```

Severity mapping comes from Slither impact + confidence, with overrides for selected detectors (e.g., `reentrancy-eth` → Critical, `arbitrary-send-eth` → Critical, `unchecked-lowlevel` → High).

## 9. UX overview

1. **Landing** — one-line pitch, 20-second GIF of a reentrancy run, tech badges, "Try the Lab" button.
2. **Lab** — scenario grid.
3. **Scenario page** — left: code tabs (Vulnerable / Secure / Attacker) with diff toggle; right: controls (Mode toggle, Run, Step), flow graph, loss panel, tx table, explanation.
4. **Analyzer** — upload/paste, progress, score gauge, severity bar, findings list with code highlighting.
5. **Proof Matrix** — 8 × 2 grid of pass/fail badges.

## 10. Success metrics (portfolio context)

- All 16 scenario/mode combinations pass in CI.
- Public demo URL, README with architecture diagram and GIFs.
- ≥ 90% line coverage on lab contracts.
- Analyzer correctly flags the known issues in all 8 vulnerable contracts (self-test).

## 11. Milestones

| Milestone | Scope | Est. |
|-----------|-------|------|
| M0 | Repo, monorepo tooling, Docker, CI skeleton | 2 days |
| M1 | Foundry lab: S1–S4 contracts + tests | 4 days |
| M2 | Foundry lab: S5–S8 contracts + tests | 4 days |
| M3 | Backend run engine + trace capture | 4 days |
| M4 | Frontend Lab UI + flow graph | 5 days |
| M5 | Analyzer (Slither pipeline, scoring, reports) | 4 days |
| M6 | Proof matrix, Hardhat workspace, polish, E2E | 3 days |
| M7 | Deploy, README, demo video | 2 days |

## 12. Risks

| Risk | Mitigation |
|------|------------|
| Slither fails on unusual imports/pragmas | Pinned solc versions, clear error messages, OpenZeppelin remappings only |
| Front-running is hard to show on an automining chain | Disable automine for S6, control ordering explicitly via mempool + priority fee |
| Trace output is noisy | Filter to user-relevant frames; collapse library calls |
| Scope creep | Ship S1, S2, S8 end-to-end first, then add the rest |

## 13. Open questions

- Host the analyzer publicly or demo-only with rate limits?
- Add Aderyn or Mythril as a second analyzer in v2?
- Add an AI "explain this finding" feature in v2?
