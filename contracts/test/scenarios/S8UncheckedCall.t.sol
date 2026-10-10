// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockNonStandardERC20} from "../../src/common/MockNonStandardERC20.sol";
import {VulnerablePayout} from "../../src/scenarios/s8_unchecked_call/VulnerablePayout.sol";
import {SecurePayout} from "../../src/scenarios/s8_unchecked_call/SecurePayout.sol";
import {Attacker} from "../../src/scenarios/s8_unchecked_call/Attacker.sol";

contract S8UncheckedCallTest is Test {
    MockNonStandardERC20 internal token;
    VulnerablePayout internal vulnerable;
    SecurePayout internal secure;
    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    address internal constant USER1 = address(0xA11CE);
    address internal constant USER2 = address(0xB0B);

    uint256 internal constant ETH_FUND = 10 ether;
    uint256 internal constant TOKEN_FUND = 10e18;

    function setUp() public {
        token = new MockNonStandardERC20("Lab Token", "LAB", 18);

        vulnerable = new VulnerablePayout(token);
        secure = new SecurePayout(token);

        attackerVuln = new Attacker(address(vulnerable));
        attackerSec = new Attacker(address(secure));

        vulnerable.deposit{value: ETH_FUND}();
        secure.deposit{value: ETH_FUND}();

        token.mint(address(this), 2 * TOKEN_FUND);
        token.approve(address(vulnerable), TOKEN_FUND);
        vulnerable.depositToken(TOKEN_FUND);
        token.approve(address(secure), TOKEN_FUND);
        secure.depositToken(TOKEN_FUND);

        assertEq(address(vulnerable).balance, ETH_FUND);
        assertEq(address(secure).balance, ETH_FUND);
        assertEq(token.balanceOf(address(vulnerable)), TOKEN_FUND);
        assertEq(token.balanceOf(address(secure)), TOKEN_FUND);
    }

    /*//////////////////////////////////////////////////////////////
                       THE EXPLOIT (vulnerable)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The desk records an ETH payment to a recipient that refused it.
     */
    function test_unchecked_eth_payout_records_payment_that_never_happened() public {
        attackerVuln.attack();

        assertEq(vulnerable.totalEthPaid(), ETH_FUND, "ledger claims it paid");
        assertEq(address(attackerVuln).balance, 0, "recipient received nothing");
        assertEq(address(vulnerable).balance, ETH_FUND, "the ETH never left the desk");
        assertEq(attackerVuln.profit(), 0, "S8 is not a theft");
    }

    /**
     * @notice A non-standard token returning `false` is silently accepted.
     */
    function test_unchecked_token_payout_records_payment_that_never_happened() public {
        token.setTransferFails(true);

        vulnerable.payoutToken(USER1, 5e18);

        assertEq(vulnerable.totalTokenPaid(), 5e18, "ledger claims it paid");
        assertEq(token.balanceOf(USER1), 0, "no tokens arrived");
        assertEq(token.balanceOf(address(vulnerable)), TOKEN_FUND, "tokens still held");
    }

    /*//////////////////////////////////////////////////////////////
                        THE DEFENSE (secure)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The secure desk reverts when the recipient rejects ETH.
     */
    function test_secure_eth_payout_reverts() public {
        vm.expectRevert(SecurePayout.TransferFailed.selector);
        attackerSec.attack();

        assertEq(address(secure).balance, ETH_FUND, "funds untouched");
        assertEq(secure.totalEthPaid(), 0, "ledger untouched");
    }

    /**
     * @notice SafeERC20 turns the token's `false` into a revert.
     */
    function test_secure_token_payout_reverts() public {
        token.setTransferFails(true);

        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
        );
        secure.payoutToken(USER1, 5e18);

        assertEq(secure.totalTokenPaid(), 0, "ledger untouched");
        assertEq(token.balanceOf(USER1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          NORMAL BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Paying a normal EOA works on both desks.
     */
    function test_eth_payout_works_when_recipient_accepts() public {
        uint256 user1Before = USER1.balance;
        vulnerable.payout(payable(USER1), 5 ether);
        assertEq(USER1.balance, user1Before + 5 ether);
        assertEq(vulnerable.totalEthPaid(), 5 ether);
        assertEq(address(vulnerable).balance, 5 ether);

        uint256 user2Before = USER2.balance;
        secure.payout(payable(USER2), 5 ether);
        assertEq(USER2.balance, user2Before + 5 ether);
        assertEq(secure.totalEthPaid(), 5 ether);
        assertEq(address(secure).balance, 5 ether);
    }

    /**
     * @notice Honest token payouts still work while the token behaves.
     */
    function testFuzz_token_payout_works(uint256 amount) public {
        amount = bound(amount, 1, TOKEN_FUND);

        vulnerable.payoutToken(USER1, amount);
        secure.payoutToken(USER2, amount);

        assertEq(token.balanceOf(USER1), amount);
        assertEq(token.balanceOf(USER2), amount);
        assertEq(vulnerable.totalTokenPaid(), amount);
        assertEq(secure.totalTokenPaid(), amount);
    }

    /**
     * @notice The adversary never actually holds funds.
     */
    function test_attacker_profit_is_zero() public view {
        assertEq(attackerVuln.profit(), 0);
        assertEq(attackerSec.profit(), 0);
    }

    /**
     * @notice The zero address is rejected on both desks.
     */
    function test_revertWhen_payingZeroAddress() public {
        vm.expectRevert(VulnerablePayout.ZeroAddress.selector);
        vulnerable.payout(payable(address(0)), 1 ether);

        vm.expectRevert(VulnerablePayout.ZeroAddress.selector);
        vulnerable.payoutToken(address(0), 1e18);

        vm.expectRevert(SecurePayout.ZeroAddress.selector);
        secure.payout(payable(address(0)), 1 ether);

        vm.expectRevert(SecurePayout.ZeroAddress.selector);
        secure.payoutToken(address(0), 1e18);
    }
}
