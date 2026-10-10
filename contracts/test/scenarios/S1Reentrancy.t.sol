// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {VulnerableVault} from "../../src/scenarios/s1_reentrancy/VulnerableVault.sol";
import {SecureVault} from "../../src/scenarios/s1_reentrancy/SecureVault.sol";
import {Attacker} from "../../src/scenarios/s1_reentrancy/Attacker.sol";
import {IVault} from "../../src/scenarios/s1_reentrancy/IVault.sol";

/**
 * @dev Minimal contract that deposits and withdraws through {IVault} but
 *      rejects every incoming payment with no revert data. Used to exercise the
 *      vaults' `TransferFailed` path, which a plain EOA can never reach.
 */
contract RejectingRecipient {
    function depositTo(IVault vault, uint256 amount) external {
        vault.deposit{value: amount}();
    }

    function withdrawFrom(IVault vault) external {
        vault.withdraw();
    }

    receive() external payable {
        revert();
    }
}

contract S1ReentrancyTest is Test {
    VulnerableVault internal vulnerable;
    SecureVault internal secure;
    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    address internal constant USER1 = address(0xA11CE);
    address internal constant USER2 = address(0xB0B);
    address internal constant USER3 = address(0xC0DE);

    /// @notice Total ETH the three victims deposit into each vault.
    uint256 internal constant VICTIM_FUND = 10 ether;

    function setUp() public {
        vulnerable = new VulnerableVault();
        secure = new SecureVault();

        attackerVuln = new Attacker(address(vulnerable));
        attackerSec = new Attacker(address(secure));

        // The attacker self-funds the seed from this balance (see the pranks
        // below). The three users fund both vaults, 6/6/8 ETH in total.
        vm.deal(address(attackerVuln), 1 ether);
        vm.deal(address(attackerSec), 1 ether);
        vm.deal(USER1, 10 ether);
        vm.deal(USER2, 10 ether);
        vm.deal(USER3, 10 ether);

        vm.prank(USER1);
        vulnerable.deposit{value: 3 ether}();
        vm.prank(USER2);
        vulnerable.deposit{value: 3 ether}();
        vm.prank(USER3);
        vulnerable.deposit{value: 4 ether}();

        vm.prank(USER1);
        secure.deposit{value: 3 ether}();
        vm.prank(USER2);
        secure.deposit{value: 3 ether}();
        vm.prank(USER3);
        secure.deposit{value: 4 ether}();

        assertEq(address(vulnerable).balance, VICTIM_FUND);
        assertEq(address(secure).balance, VICTIM_FUND);
    }

    /*//////////////////////////////////////////////////////////////
                        THE EXPLOIT (vulnerable)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The attacker's re-entrant withdraw drains the vulnerable vault.
     */
    function test_exploit_succeeds_on_vulnerable() public {
        uint256 vaultBefore = address(vulnerable).balance;

        vm.prank(address(attackerVuln));
        attackerVuln.attack{value: 1 ether}();

        assertEq(address(vulnerable).balance, 0, "vault should be drained");
        assertEq(attackerVuln.profit(), vaultBefore, "attacker takes the whole 10 ETH");
        assertEq(
            address(attackerVuln).balance,
            1 ether + vaultBefore,
            "seed returned plus the drained ETH"
        );

        // The victims' ledger entries are never cleared, but the ETH is gone.
        assertEq(vulnerable.balanceOf(USER1), 3 ether);
        assertEq(vulnerable.balanceOf(USER2), 3 ether);
        assertEq(vulnerable.balanceOf(USER3), 4 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         THE DEFENSE (secure)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The same attacker reverts against CEI + ReentrancyGuard.
     */
    function test_exploit_fails_on_secure() public {
        vm.prank(address(attackerSec));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attackerSec.attack{value: 1 ether}();
    }

    /**
     * @notice Nothing moved, and the attacker is out nothing.
     */
    function test_secure_vault_is_untouched_after_failed_attack() public {
        vm.prank(address(attackerSec));
        try attackerSec.attack{value: 1 ether}() {
            revert("attack should have reverted");
        } catch {}

        assertEq(address(secure).balance, VICTIM_FUND, "vault keeps all 10 ETH");
        assertEq(attackerSec.profit(), 0, "no profit");
        assertEq(attackerSec.drained(), 0, "nothing was ever paid out");
        assertEq(address(attackerSec).balance, 1 ether, "seed was refunded by the revert");
    }

    /*//////////////////////////////////////////////////////////////
                          NORMAL BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Honest deposit/withdraw round trips work on the secure vault.
     */
    function testFuzz_normal_deposit_withdraw(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 100 ether);

        address user = address(0x9999);
        vm.deal(user, depositAmount);
        uint256 startingBalance = user.balance;

        vm.prank(user);
        secure.deposit{value: depositAmount}();
        assertEq(secure.balanceOf(user), depositAmount, "credited on deposit");
        assertEq(address(secure).balance, VICTIM_FUND + depositAmount);

        vm.prank(user);
        secure.withdraw();
        assertEq(secure.balanceOf(user), 0, "cleared on withdraw");
        assertEq(user.balance, startingBalance, "made whole");
        assertEq(address(secure).balance, VICTIM_FUND, "back to the victims' ETH");
    }

    /**
     * @notice Normal path is unaffected on the vulnerable vault too.
     */
    function test_vulnerable_vault_handles_honest_users() public {
        vm.prank(USER1);
        vulnerable.withdraw();

        assertEq(vulnerable.balanceOf(USER1), 0);
        // USER1 started with 10 ETH, paid 3 into each vault (6), then withdrew
        // 3 here: 10 - 6 + 3 == 7.
        assertEq(USER1.balance, 7 ether, "surplus after the two deposits and one withdrawal");
        assertEq(address(vulnerable).balance, 7 ether);
    }

    /**
     * @notice Withdrawing with no deposit is rejected on both vaults.
     */
    function test_revertWhen_withdrawingWithNoBalance() public {
        address nobody = address(0xDEAD);

        vm.prank(nobody);
        vm.expectRevert(SecureVault.InsufficientBalance.selector);
        secure.withdraw();

        vm.prank(nobody);
        vm.expectRevert(VulnerableVault.InsufficientBalance.selector);
        vulnerable.withdraw();
    }

    /**
     * @notice Depositing nothing is rejected on both vaults.
     */
    function test_revertWhen_depositingZero() public {
        vm.expectRevert(SecureVault.ZeroDeposit.selector);
        secure.deposit();

        vm.expectRevert(VulnerableVault.ZeroDeposit.selector);
        vulnerable.deposit();
    }

    /**
     * @notice A recipient that refuses ETH makes the payout fail cleanly on
     *         both vaults rather than silently losing funds.
     */
    function test_revertWhen_recipientRejectsPayment() public {
        RejectingRecipient recipient = new RejectingRecipient();
        vm.deal(address(recipient), 2 ether);

        recipient.depositTo(vulnerable, 1 ether);
        vm.expectRevert(VulnerableVault.TransferFailed.selector);
        recipient.withdrawFrom(vulnerable);

        recipient.depositTo(secure, 1 ether);
        vm.expectRevert(SecureVault.TransferFailed.selector);
        recipient.withdrawFrom(secure);
    }

    /**
     * @notice The secure vault refuses unsolicited ETH, so its real balance can
     *         only change through deposit/withdraw. This is what makes the
     *         ledger invariant below hold unconditionally.
     */
    function test_secure_vault_rejects_unsolicited_eth() public {
        vm.deal(address(this), 1 ether);

        (bool ok,) = address(secure).call{value: 1 ether}("");

        assertFalse(ok, "unsolicited ETH must be rejected");
        assertEq(address(secure).balance, VICTIM_FUND);
    }

    /**
     * @notice An attack with no seed cannot get started.
     */
    function test_revertWhen_attackingWithoutSeed() public {
        vm.expectRevert(Attacker.MissingSeed.selector);
        attackerVuln.attack();

        vm.expectRevert(Attacker.MissingSeed.selector);
        attackerSec.attack();
    }

    /**
     * @notice `profit()` reports zero before any ETH has been drained.
     */
    function test_profitIsZeroBeforeAnyAttack() public view {
        assertEq(attackerVuln.profit(), 0);
        assertEq(attackerSec.profit(), 0);
    }
}

/**
 * @dev Drives deposit/withdraw for a small fixed cast of actors so the
 *      pipeline can hash through many orderings of the two calls.
 */
contract SecureVaultHandler is Test {
    SecureVault internal immutable vault;
    address[] internal actors;

    constructor(SecureVault vault_) {
        vault = vault_;
        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        amount = bound(amount, 1, 50 ether);

        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        vault.deposit{value: amount}();
    }

    function withdraw(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        if (vault.balanceOf(actor) == 0) {
            return;
        }

        vm.prank(actor);
        vault.withdraw();
    }
}

/**
 * @notice Invariant: for SecureVault the sum of every actor's internal balance
 *         must always equal the ETH actually held by the contract.
 */
contract S1ReentrancyInvariantTest is StdInvariant, Test {
    SecureVault internal vault;
    SecureVaultHandler internal handler;

    function setUp() public {
        vault = new SecureVault();
        handler = new SecureVaultHandler(vault);

        targetContract(address(handler));
    }

    function invariant_sumOfBalancesEqualsContractBalance() public view {
        uint256 sum;
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            sum += vault.balanceOf(handler.actorAt(i));
        }

        assertEq(sum, address(vault).balance, "internal ledger must match real ETH");
    }
}
