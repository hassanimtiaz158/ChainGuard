# ChainGuard contracts (Foundry)

The deliberately vulnerable contracts, their hardened counterparts, and the
Foundry tests that prove the exploit works on one and fails on the other.

**These contracts are attack targets on purpose.** They are never deployed to
mainnet or any public testnet — only to the bundled local Anvil chain (chain ID
31337).

## Setup

```bash
forge install --no-git --shallow foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.7.0
forge build
```

or from the repo root: `make deps`.

## Layout

```
src/
├── common/                     # MockERC20, MockAMM, MockLender, MockOracle
└── scenarios/
    ├── s1_reentrancy/          # VulnerableVault.sol, SecureVault.sol, Attacker.sol
    ├── s2_access_control/
    ├── s3_logic/
    ├── s4_oracle/
    ├── s5_flashloan/
    ├── s6_frontrun/
    ├── s7_sig_replay/
    └── s8_unchecked_call/
script/DeployLab.s.sol          # deploys everything, writes deployments/lab.json
test/
├── common/                     # unit tests for the mocks
├── scenarios/                  # S1Reentrancy.t.sol, ...
└── invariants/
```

## Conventions

- Solidity `0.8.24`, OpenZeppelin v5.

### Pinned dependencies

Installed with `forge install --no-git --shallow`:

| Library | Version |
|---------|---------|
| `forge-std` | v1.17.0 |
| `openzeppelin-contracts` | v5.7.0 |

### OpenZeppelin v5.7 API notes

Verified against the vendored source; these two details break the compiler if
you copy an older v5 example:

- **`ERC20._update` argument order changed** to `(address from, address to, uint256 value)`.
  Override it with that exact signature.
- **`ERC20Votes` already inherits `EIP712` and `Nonces`** via
  `Votes is Context, EIP712, Nonces, IERC5805`. Do not list `EIP712`/`Nonces`
  in an `ERC20Votes` child's inheritance list (C3 linearization failure), but you
  *must* still forward the constructor arguments:
  `constructor() ERC20("X", "X") EIP712("X", "1") {}`.
- Every scenario exposes the same shape so the run engine can treat them
  generically: a `Vulnerable*` and a `Secure*` pair sharing an interface
  (`IVault`, `IWallet`, ...), plus an `Attacker` that takes the target address
  in its constructor and exposes `attack()` and `profit()`.

## Tests

```bash
forge test            # all suites
forge test -vvv       # verbose (CI)
forge coverage        # >= 90% lines on src/scenarios
forge fmt --check
```