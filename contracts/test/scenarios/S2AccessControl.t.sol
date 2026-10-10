// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {VulnerableWallet} from "../../src/scenarios/s2_access_control/VulnerableWallet.sol";
import {SecureWallet} from "../../src/scenarios/s2_access_control/SecureWallet.sol";
import {Attacker} from "../../src/scenarios/s2_access_control/Attacker.sol";
import {IWallet} from "../../src/scenarios/s2_access_control/IWallet.sol";

/**
 * @dev Stand-in for a malicious dApp the real owner interacts with. Because the
 *      vulnerable wallet authorises with `tx.origin`, the owner's own call hands
 *      this contract the owner's authority.
 */
contract Phisher {
    function lure(IWallet wallet, address payable to) external {
        wallet.emergencyWithdraw(to);
    }
}

/**
 * @dev Deposits and withdraws through {IWallet} but rejects every incoming
 *      payment, exercising the wallets' `TransferFailed` path.
 */
contract RejectingRecipient {
    function depositTo(IWallet wallet, uint256 amount) external {
        wallet.deposit{value: amount}();
    }

    function withdrawFrom(IWallet wallet) external {
        wallet.withdraw();
    }

    receive() external payable {
        revert();
    }
}

contract S2AccessControlTest is Test {
    VulnerableWallet internal vulnerable;
    SecureWallet internal secure;
    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    address internal constant OWNER = address(0x0FF1CE);
    address internal constant USER1 = address(0xA11CE);
    address internal constant USER2 = address(0xB0B);
    address internal constant USER3 = address(0xC0DE);
    address payable internal constant TREASURY = payable(address(0x7EA5));

    uint256 internal constant VICTIM_FUND = 10 ether;

    /// @dev Receives swept funds: the attacker's beneficiary is the deployer.
    receive() external payable {}

    function setUp() public {
        vulnerable = new VulnerableWallet();
        secure = new SecureWallet();

        attackerVuln = new Attacker(address(vulnerable));
        attackerSec = new Attacker(address(secure));

        // Hand ownership to a named EOA so the tx.origin phishing test is
        // explicit about who the genuine owner is.
        vulnerable.setOwner(OWNER);
        secure.setOwner(OWNER);

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
     * @notice Anyone can claim ownership and then sweep the wallet.
     */
    function test_exploit_succeeds_on_vulnerable() public {
        assertEq(vulnerable.owner(), OWNER);
        uint256 balanceBefore = address(this).balance;

        attackerVuln.attack();

        assertEq(vulnerable.owner(), address(attackerVuln), "attacker took ownership");
        assertEq(address(vulnerable).balance, 0, "wallet drained");
        assertEq(attackerVuln.profit(), VICTIM_FUND, "attacker takes the whole 10 ETH");
        assertEq(
            address(this).balance, balanceBefore + VICTIM_FUND, "beneficiary received the funds"
        );
    }

    /**
     * @notice The `tx.origin` bug lets a phishing contract spend the owner's
     *         authority inside the owner's own transaction.
     */
    function test_phishing_through_txOrigin_drains_vulnerable() public {
        Phisher phisher = new Phisher();

        vm.prank(OWNER, OWNER);
        phisher.lure(vulnerable, TREASURY);

        assertEq(address(vulnerable).balance, 0, "wallet drained via tx.origin");
        assertEq(TREASURY.balance, VICTIM_FUND, "phisher redirected the funds");
        assertEq(vulnerable.owner(), OWNER, "ownership never changed");
    }

    /*//////////////////////////////////////////////////////////////
                        THE DEFENSE (secure)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The same attacker reverts against OpenZeppelin Ownable.
     */
    function test_exploit_fails_on_secure() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector, address(attackerSec)
            )
        );
        attackerSec.attack();

        assertEq(address(secure).balance, VICTIM_FUND, "funds untouched");
        assertEq(attackerSec.profit(), 0);
    }

    /**
     * @notice The phishing contract has no authority on the secure wallet.
     */
    function test_phishing_fails_on_secure() public {
        Phisher phisher = new Phisher();

        vm.prank(OWNER, OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(phisher))
        );
        phisher.lure(secure, TREASURY);

        assertEq(address(secure).balance, VICTIM_FUND, "funds untouched");
    }

    /*//////////////////////////////////////////////////////////////
                          NORMAL BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Honest deposit/withdraw round trips work on the secure wallet.
     */
    function testFuzz_normal_deposit_withdraw(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 100 ether);

        address user = address(0x9999);
        vm.deal(user, depositAmount);
        uint256 startingBalance = user.balance;

        vm.prank(user);
        secure.deposit{value: depositAmount}();
        assertEq(secure.balanceOf(user), depositAmount);
        assertEq(address(secure).balance, VICTIM_FUND + depositAmount);

        vm.prank(user);
        secure.withdraw();
        assertEq(secure.balanceOf(user), 0);
        assertEq(user.balance, startingBalance, "made whole");
        assertEq(address(secure).balance, VICTIM_FUND);
    }

    /**
     * @notice The vulnerable wallet still settles honest withdrawals.
     */
    function test_vulnerable_withdraw_works() public {
        vm.prank(USER1);
        vulnerable.withdraw();

        assertEq(vulnerable.balanceOf(USER1), 0);
        assertEq(address(vulnerable).balance, 7 ether, "USER1's 3 ETH left the wallet");
    }

    /**
     * @notice The legitimate owner can transfer ownership and sweep.
     */
    function test_secure_owner_actions_work() public {
        vm.prank(OWNER);
        secure.setOwner(USER1);
        assertEq(secure.owner(), USER1);

        vm.prank(USER1);
        secure.sweep(TREASURY);
        assertEq(address(secure).balance, 0);
        assertEq(TREASURY.balance, VICTIM_FUND);
    }

    /**
     * @notice The owner can also use the emergency drain legitimately.
     */
    function test_secure_emergencyWithdraw_works() public {
        vm.prank(OWNER, OWNER);
        secure.emergencyWithdraw(TREASURY);

        assertEq(address(secure).balance, 0);
        assertEq(TREASURY.balance, VICTIM_FUND);
    }

    /**
     * @notice `profit()` is zero before anything is taken.
     */
    function test_profitIsZeroBeforeAnyAttack() public view {
        assertEq(attackerVuln.profit(), 0);
        assertEq(attackerSec.profit(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             REVERT PATHS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdrawing with no deposit is rejected on both wallets.
     */
    function test_revertWhen_withdrawingWithNoBalance() public {
        address nobody = address(0xDEAD);

        vm.prank(nobody);
        vm.expectRevert(SecureWallet.InsufficientBalance.selector);
        secure.withdraw();

        vm.prank(nobody);
        vm.expectRevert(VulnerableWallet.InsufficientBalance.selector);
        vulnerable.withdraw();
    }

    /**
     * @notice A non-owner cannot sweep either wallet.
     */
    function test_revertWhen_nonOwnerSweeps() public {
        vm.prank(USER1);
        vm.expectRevert(VulnerableWallet.NotOwner.selector);
        vulnerable.sweep(TREASURY);

        vm.prank(USER1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER1));
        secure.sweep(TREASURY);
    }

    /**
     * @notice A caller that is not the owner's transaction is refused.
     */
    function test_revertWhen_emergencyWithdrawFromWrongOrigin() public {
        vm.prank(USER1, USER1);
        vm.expectRevert(VulnerableWallet.NotOwner.selector);
        vulnerable.emergencyWithdraw(TREASURY);
    }

    /**
     * @notice The zero address is rejected everywhere an address is taken.
     */
    function test_revertWhen_zeroAddress() public {
        vm.expectRevert(VulnerableWallet.ZeroAddress.selector);
        vulnerable.setOwner(address(0));

        vm.expectRevert(VulnerableWallet.ZeroAddress.selector);
        vulnerable.sweep(payable(address(0)));

        vm.expectRevert(VulnerableWallet.ZeroAddress.selector);
        vulnerable.emergencyWithdraw(payable(address(0)));

        vm.prank(OWNER);
        vm.expectRevert(SecureWallet.ZeroAddress.selector);
        secure.setOwner(address(0));

        vm.prank(OWNER);
        vm.expectRevert(SecureWallet.ZeroAddress.selector);
        secure.sweep(payable(address(0)));

        vm.prank(OWNER);
        vm.expectRevert(SecureWallet.ZeroAddress.selector);
        secure.emergencyWithdraw(payable(address(0)));
    }

    /**
     * @notice A payout to a recipient that refuses ETH fails cleanly, not
     *         silently, on both wallets.
     */
    function test_revertWhen_recipientRejectsPayment() public {
        RejectingRecipient recipient = new RejectingRecipient();
        vm.deal(address(recipient), 2 ether);

        recipient.depositTo(vulnerable, 1 ether);
        vm.expectRevert(VulnerableWallet.TransferFailed.selector);
        recipient.withdrawFrom(vulnerable);

        recipient.depositTo(secure, 1 ether);
        vm.expectRevert(SecureWallet.TransferFailed.selector);
        recipient.withdrawFrom(secure);
    }

    /**
     * @notice Sweeping and emergency-draining to a refusing recipient fail too.
     */
    function test_revertWhen_sweepingToRejectingRecipient() public {
        RejectingRecipient recipient = new RejectingRecipient();

        vm.prank(OWNER);
        vm.expectRevert(VulnerableWallet.TransferFailed.selector);
        vulnerable.sweep(payable(address(recipient)));

        vm.prank(OWNER, OWNER);
        vm.expectRevert(VulnerableWallet.TransferFailed.selector);
        vulnerable.emergencyWithdraw(payable(address(recipient)));

        vm.prank(OWNER);
        vm.expectRevert(SecureWallet.TransferFailed.selector);
        secure.sweep(payable(address(recipient)));

        vm.prank(OWNER, OWNER);
        vm.expectRevert(SecureWallet.TransferFailed.selector);
        secure.emergencyWithdraw(payable(address(recipient)));
    }
}
