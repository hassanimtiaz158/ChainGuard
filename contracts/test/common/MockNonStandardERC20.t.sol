// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockNonStandardERC20} from "../../src/common/MockNonStandardERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev A minimal payout contract, the shape a real vault would have. The
 *      `pay` / `payFrom` pair is the safe version; `payUnsafe` is the S8
 *      bug: it discards the boolean and keeps going. The pair has to live in
 *      a separate contract so `vm.expectRevert` binds to a real external
 *      call rather than to the inner `token.transfer` hop.
 */
contract PayoutCaller {
    using SafeERC20 for MockNonStandardERC20;

    MockNonStandardERC20 internal immutable TOKEN;

    constructor(MockNonStandardERC20 token) {
        TOKEN = token;
    }

    function pay(address to, uint256 amount) external {
        TOKEN.safeTransfer(to, amount);
    }

    function payFrom(address from, address to, uint256 amount) external {
        TOKEN.safeTransferFrom(from, to, amount);
    }

    /// @notice The S8 defect: the return value is never checked.
    function payUnsafe(address to, uint256 amount) external returns (bool) {
        return TOKEN.transfer(to, amount);
    }
}

/**
 * @dev These tests pin down the exact S8 hazard: a token whose transfer
 *      functions *return false* instead of reverting. A caller that ignores
 *      the return value believes it paid; a caller using SafeERC20 reverts.
 */
contract MockNonStandardERC20Test is Test {
    using SafeERC20 for MockNonStandardERC20;

    MockNonStandardERC20 internal token;
    PayoutCaller internal callerContract;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    /// @notice ALICE and the payout helper are each funded with 100e18.
    uint256 internal constant TOTAL_SUPPLY = 200e18;

    function setUp() public {
        token = new MockNonStandardERC20("Non Standard", "NS", 18);
        callerContract = new PayoutCaller(token);
        token.mint(ALICE, 100e18);
        token.mint(address(callerContract), 100e18);

        vm.prank(ALICE);
        token.approve(address(callerContract), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        HAPPY PATH (returns true)
    //////////////////////////////////////////////////////////////*/

    function test_TransferReturnsTrueByDefault() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 10e18));
        assertEq(token.balanceOf(BOB), 10e18);
    }

    function test_TransferFromReturnsTrueByDefault() public {
        vm.prank(ALICE);
        token.approve(BOB, 10e18);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 10e18));
        assertEq(token.balanceOf(BOB), 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                    FAILING PATH (returns false)
    //////////////////////////////////////////////////////////////*/

    function test_TransferReturnsFalseAndMovesNothing() public {
        token.setTransferFails(true);
        assertTrue(token.transferFails());

        vm.prank(ALICE);
        bool ok = token.transfer(BOB, 10e18);

        assertFalse(ok, "must report failure instead of reverting");
        assertEq(token.balanceOf(BOB), 0, "no tokens moved");
        assertEq(token.balanceOf(ALICE), 100e18, "sender balance untouched");
        assertEq(token.totalSupply(), TOTAL_SUPPLY, "supply untouched");
    }

    function test_TransferFromReturnsFalseAndMovesNothing() public {
        vm.prank(ALICE);
        token.approve(BOB, 10e18);
        token.setTransferFromFails(true);
        assertTrue(token.transferFromFails());

        vm.prank(BOB);
        bool ok = token.transferFrom(ALICE, BOB, 10e18);

        assertFalse(ok);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(ALICE, BOB), 10e18, "allowance not consumed");
    }

    function test_FailureFlagIsReversible() public {
        token.setTransferFails(true);

        vm.prank(ALICE);
        assertFalse(token.transfer(BOB, 1e18));

        token.setTransferFails(false);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1e18));
        assertEq(token.balanceOf(BOB), 1e18);
    }

    function test_FlagsAreIndependent() public {
        token.setTransferFails(true);

        // transferFrom must still work even though transfer is broken.
        vm.prank(ALICE);
        token.approve(BOB, 5e18);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 5e18));
    }

    /*//////////////////////////////////////////////////////////////
               WHY SAFERC20 IS THE FIX (scenario S8)
    //////////////////////////////////////////////////////////////*/

    function test_SafeERC20RevertsWhenTransferReturnsFalse() public {
        token.setTransferFails(true);

        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
        );
        callerContract.pay(BOB, 10e18);
    }

    function test_SafeERC20SucceedsWhenTokenReturnsTrue() public {
        callerContract.pay(BOB, 10e18);

        assertEq(token.balanceOf(BOB), 10e18);
    }

    function test_SafeERC20RevertsWhenTransferFromReturnsFalse() public {
        token.setTransferFromFails(true);

        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
        );
        callerContract.payFrom(ALICE, BOB, 10e18);
    }

    function test_SafeTransferFromSucceedsWhenTokenReturnsTrue() public {
        callerContract.payFrom(ALICE, BOB, 10e18);

        assertEq(token.balanceOf(BOB), 10e18);
    }

    /// @notice The S8 lesson in one test: identical call site, opposite outcome.
    function test_UncheckedPayoutSilentlyPaysNothing() public {
        token.setTransferFails(true);

        assertFalse(callerContract.payUnsafe(BOB, 10e18), "token reports failure");
        assertEq(token.balanceOf(BOB), 0, "and no tokens moved");
        assertEq(token.balanceOf(address(callerContract)), 100e18, "the caller kept its funds");
    }

    function test_UncheckedPayoutPaysNormallyOnAStandardToken() public {
        assertTrue(callerContract.payUnsafe(BOB, 10e18));
        assertEq(token.balanceOf(BOB), 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_FailedTransferNeverMovesTokens(address from, address to, uint256 amount)
        public
    {
        vm.assume(from != address(0) && from != address(this));
        vm.assume(to != address(0) && to != address(this));
        token.setTransferFails(true);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        assertFalse(token.transfer(to, amount));

        assertEq(token.balanceOf(from), fromBefore, "sender balance untouched");
        assertEq(token.balanceOf(to), toBefore, "recipient balance untouched");
    }
}
