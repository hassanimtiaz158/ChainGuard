// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {MockAMM} from "../src/common/MockAMM.sol";
import {MockERC20} from "../src/common/MockERC20.sol";
import {MockLender} from "../src/common/MockLender.sol";
import {MockNonStandardERC20} from "../src/common/MockNonStandardERC20.sol";
import {IPriceSource, MockTWAPOracle} from "../src/common/MockTWAPOracle.sol";

import {SecureVault} from "../src/scenarios/s1_reentrancy/SecureVault.sol";
import {VulnerableVault} from "../src/scenarios/s1_reentrancy/VulnerableVault.sol";

import {SecureWallet} from "../src/scenarios/s2_access_control/SecureWallet.sol";
import {VulnerableWallet} from "../src/scenarios/s2_access_control/VulnerableWallet.sol";

import {SecureToken} from "../src/scenarios/s3_integer_logic/SecureToken.sol";
import {VulnerableToken} from "../src/scenarios/s3_integer_logic/VulnerableToken.sol";

import {SecureLending} from "../src/scenarios/s4_oracle/SecureLending.sol";
import {VulnerableLending} from "../src/scenarios/s4_oracle/VulnerableLending.sol";

import {GovernanceToken} from "../src/scenarios/s5_flashloan/GovernanceToken.sol";
import {SecureGovernance} from "../src/scenarios/s5_flashloan/SecureGovernance.sol";
import {VulnerableGovernance} from "../src/scenarios/s5_flashloan/VulnerableGovernance.sol";

import {SecureQuiz} from "../src/scenarios/s6_frontrun/SecureQuiz.sol";
import {SecureSwap} from "../src/scenarios/s6_frontrun/SecureSwap.sol";
import {VulnerableQuiz} from "../src/scenarios/s6_frontrun/VulnerableQuiz.sol";
import {VulnerableSwap} from "../src/scenarios/s6_frontrun/VulnerableSwap.sol";

import {SecureClaim} from "../src/scenarios/s7_sig_replay/SecureClaim.sol";
import {VulnerableClaim} from "../src/scenarios/s7_sig_replay/VulnerableClaim.sol";

import {SecurePayout} from "../src/scenarios/s8_unchecked_call/SecurePayout.sol";
import {VulnerablePayout} from "../src/scenarios/s8_unchecked_call/VulnerablePayout.sol";

/**
 * @title DeployLab
 * @notice Deploys every scenario's vulnerable and secure contracts onto the
 *         local lab chain, funds the victims with deterministic amounts, and
 *         writes `deployments/lab.json` (TDD section 3.3).
 * @dev Run against Anvil only:
 *
 *      `forge script script/DeployLab.s.sol \
 *          --rpc-url http://127.0.0.1:8545 --broadcast --slow \
 *          --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
 *
 *      Attacker contracts are NOT deployed here: the engine deploys the
 *      `attackerArtifact` per run (see TDD section 5.2) so each scenario starts
 *      from a clean base snapshot.
 */
contract DeployLab is Script {
    /// @notice The only chain this lab ever talks to.
    uint256 internal constant CHAIN_ID = 31337;

    /// @notice ETH handed to each ETH-holding victim.
    uint256 internal constant VICTIM_FUND = 10 ether;

    /// @notice ERC20 handed to the S8 payout desk.
    uint256 internal constant TOKEN_FUND = 10 ether;

    /// @notice S3 starting supply minted to the deployer.
    uint256 internal constant S3_SUPPLY = 1_000 ether;

    /// @notice Reserve deposited on each side of the S4 and S6 pools.
    uint256 internal constant POOL_LIQUIDITY = 1_000 ether;

    /// @notice Borrow-token liquidity each S4 lending pool can lend out.
    uint256 internal constant BORROW_LIQUIDITY = 10_000 ether;

    /// @notice Governance tokens held by each S5 treasury.
    uint256 internal constant TREASURY = 5_000_000 ether;

    /// @notice Governance tokens the S5 lender can flash-loan.
    uint256 internal constant LENDER_LIQUIDITY = 3_000_000 ether;

    /// @notice S6 quiz prize, sent as the deployment value.
    uint256 internal constant PRIZE = 5 ether;

    /// @notice ETH used to fund each S7 voucher vault.
    uint256 internal constant CLAIM_FUND = 5 ether;

    /// @dev Anvil account #1. S7 vouchers must be signed by this key, which the
    ///      runner already knows (Anvil's public default mnemonic).
    address internal constant VOUCHER_SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    /// @dev keccak256("satoshi"), the S6 quiz answer commitment.
    bytes32 internal constant ANSWER_HASH = keccak256("satoshi");

    /// @dev Path the engine reads, relative to the Foundry project root.
    string internal constant LAB_JSON = "./deployments/lab.json";

    /**
     * @notice Deploy the lab and publish `lab.json` to the shared lab volume.
     */
    function run() external {
        require(block.chainid == CHAIN_ID, "DeployLab: not the local lab chain");

        address deployer = msg.sender;

        vm.startBroadcast();

        string memory entries;
        entries = _append(entries, _deployReentrancy());
        entries = _append(entries, _deployAccessControl());
        entries = _append(entries, _deployIntegerLogic(deployer));
        entries = _append(entries, _deployOracle());
        entries = _append(entries, _deployFlashLoan());
        entries = _append(entries, _deployFrontRun());
        entries = _append(entries, _deploySignatureReplay());
        entries = _append(entries, _deployUncheckedCall());

        vm.stopBroadcast();

        string memory json = string.concat('{"chainId":', vm.toString(CHAIN_ID), ",", entries, "}");

        // `deployments/` is gitignored, so it may not exist on a fresh checkout.
        vm.createDir("./deployments", true);
        vm.writeFile(LAB_JSON, string.concat(json, "\n"));
    }

    /*//////////////////////////////////////////////////////////////
                            SCENARIO SETUP
    //////////////////////////////////////////////////////////////*/

    /// @dev S1: fund both vaults so there is ETH to drain.
    function _deployReentrancy() internal returns (string memory) {
        VulnerableVault vulnerable = new VulnerableVault();
        SecureVault secure = new SecureVault();

        vulnerable.deposit{value: VICTIM_FUND}();
        secure.deposit{value: VICTIM_FUND}();

        return _entry("s1_reentrancy", address(vulnerable), address(secure), VICTIM_FUND);
    }

    /// @dev S2: fund both wallets so the sweep has something to take.
    function _deployAccessControl() internal returns (string memory) {
        VulnerableWallet vulnerable = new VulnerableWallet();
        SecureWallet secure = new SecureWallet();

        vulnerable.deposit{value: VICTIM_FUND}();
        secure.deposit{value: VICTIM_FUND}();

        return _entry("s2_access_control", address(vulnerable), address(secure), VICTIM_FUND);
    }

    /// @dev S3: mint a starting supply on both tokens. The exploit conjures
    ///      tokens from an empty balance, so the attacker needs no funding.
    function _deployIntegerLogic(address deployer) internal returns (string memory) {
        VulnerableToken vulnerable = new VulnerableToken();
        SecureToken secure = new SecureToken();

        vulnerable.mint(deployer, S3_SUPPLY);
        secure.mint(deployer, S3_SUPPLY);

        return _entry("s3_integer_logic", address(vulnerable), address(secure), 0);
    }

    /// @dev S4: seed a 1:1 pool, give each lending pool borrow liquidity, and
    ///      prime the TWAP so the secure pool has a price window to consult.
    ///      Liquidity is minted straight to the pool and adopted with `sync`,
    ///      which keeps the script independent of the calling account.
    function _deployOracle() internal returns (string memory) {
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        MockAMM amm = new MockAMM(tokenA, tokenB, 30);

        MockTWAPOracle oracle = new MockTWAPOracle(IPriceSource(address(amm)), 60, 10);

        VulnerableLending vulnerable = new VulnerableLending(amm);
        SecureLending secure = new SecureLending(amm, oracle);

        MockERC20 collateral = amm.token0();
        MockERC20 borrow = amm.token1();

        collateral.mint(address(amm), POOL_LIQUIDITY);
        borrow.mint(address(amm), POOL_LIQUIDITY);
        amm.sync();

        borrow.mint(address(vulnerable), BORROW_LIQUIDITY);
        borrow.mint(address(secure), BORROW_LIQUIDITY);

        _primeOracle(oracle);

        return _entry("s4_oracle", address(vulnerable), address(secure), 0);
    }

    /// @dev S5: give each treasury tokens to govern and fill the flash lender.
    function _deployFlashLoan() internal returns (string memory) {
        GovernanceToken token = new GovernanceToken();

        VulnerableGovernance vulnerable = new VulnerableGovernance(token);
        SecureGovernance secure = new SecureGovernance(token);

        token.mint(address(vulnerable), TREASURY);
        token.mint(address(secure), TREASURY);

        MockLender lender = new MockLender(token);
        token.mint(address(lender), LENDER_LIQUIDITY);

        return _entry("s5_flashloan", address(vulnerable), address(secure), 0);
    }

    /// @dev S6: fund both quizzes with the prize and seed a swap pool.
    function _deployFrontRun() internal returns (string memory) {
        VulnerableQuiz vulnerable = new VulnerableQuiz{value: PRIZE}(ANSWER_HASH);
        SecureQuiz secure = new SecureQuiz{value: PRIZE}(ANSWER_HASH);

        MockERC20 tokenA = new MockERC20("Swap A", "SWA", 18);
        MockERC20 tokenB = new MockERC20("Swap B", "SWB", 18);
        MockAMM amm = new MockAMM(tokenA, tokenB, 30);

        new VulnerableSwap(amm, amm.token0(), amm.token1());
        new SecureSwap(amm, amm.token0(), amm.token1());

        amm.token0().mint(address(amm), POOL_LIQUIDITY);
        amm.token1().mint(address(amm), POOL_LIQUIDITY);
        amm.sync();

        return _entry("s6_frontrun", address(vulnerable), address(secure), PRIZE);
    }

    /// @dev S7: fund both voucher vaults. Vouchers are issued off-chain by the
    ///      runner using {VOUCHER_SIGNER}'s key.
    function _deploySignatureReplay() internal returns (string memory) {
        VulnerableClaim vulnerable = new VulnerableClaim(VOUCHER_SIGNER);
        SecureClaim secure = new SecureClaim(VOUCHER_SIGNER);

        _sendEth(address(vulnerable), CLAIM_FUND);
        _sendEth(address(secure), CLAIM_FUND);

        return _entry("s7_sig_replay", address(vulnerable), address(secure), CLAIM_FUND);
    }

    /// @dev S8: fund both payout desks with ETH and tokens.
    function _deployUncheckedCall() internal returns (string memory) {
        MockNonStandardERC20 token = new MockNonStandardERC20("Lab Token", "LAB", 18);

        VulnerablePayout vulnerable = new VulnerablePayout(token);
        SecurePayout secure = new SecurePayout(token);

        vulnerable.deposit{value: VICTIM_FUND}();
        secure.deposit{value: VICTIM_FUND}();

        token.mint(address(vulnerable), TOKEN_FUND);
        token.mint(address(secure), TOKEN_FUND);

        return _entry("s8_unchecked_call", address(vulnerable), address(secure), VICTIM_FUND);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Record a short price history so `MockTWAPOracle.consult` has a
    ///      window to average over.
    function _primeOracle(MockTWAPOracle oracle) internal {
        uint256 timestamp = vm.getBlockTimestamp();
        for (uint256 i = 0; i < 12; i++) {
            timestamp += 60;
            vm.warp(timestamp);
            oracle.update();
        }
    }

    /// @dev Transfer ETH from the deploying account.
    function _sendEth(address to, uint256 amount) internal {
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "DeployLab: ETH funding failed");
    }

    /// @dev Build one `lab.json` scenario entry (TDD section 3.3).
    function _entry(string memory id, address vulnerable, address secure, uint256 fundedWei)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '"',
            id,
            '":{"vulnerable":"',
            vm.toString(vulnerable),
            '","secure":"',
            vm.toString(secure),
            '","attackerArtifact":"Attacker","fundedWei":"',
            vm.toString(fundedWei),
            '"}'
        );
    }

    /// @dev Comma-join JSON entries while tolerating an empty accumulator.
    function _append(string memory entries, string memory entry)
        internal
        pure
        returns (string memory)
    {
        if (bytes(entries).length == 0) {
            return entry;
        }
        return string.concat(entries, ",", entry);
    }
}
