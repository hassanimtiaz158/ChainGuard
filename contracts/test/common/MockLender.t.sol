// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockERC20} from "../../src/common/MockERC20.sol";
import {IFlashLoanReceiver, MockLender} from "../../src/common/MockLender.sol";

/// @dev Borrows, optionally does something with the funds, then repays in full.
contract RepayingBorrower is IFlashLoanReceiver {
    using SafeERC20 for MockERC20;
    MockLender internal immutable LENDER;
    MockERC20 internal immutable TOKEN;

    uint256 public callbackCount;
    uint256 public lastAmount;
    uint256 public lastFee;
    bytes public lastData;

    /// @notice Loan balance observed *inside* the callback, i.e. mid-loan.
    uint256 public balanceDuringCallback;

    /// @notice Amount to repay; 0 means "repay the full principal".
    uint256 public repayAmount;

    constructor(MockLender lender, MockERC20 token) {
        LENDER = lender;
        TOKEN = token;
    }

    function setRepayAmount(uint256 value) external {
        repayAmount = value;
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata data)
        external
    {
        require(msg.sender == address(LENDER), "only lender may call");
        callbackCount++;
        lastAmount = amount;
        lastFee = fee;
        lastData = data;
        balanceDuringCallback = TOKEN.balanceOf(address(this));

        uint256 repay = repayAmount == 0 ? amount : repayAmount;
        TOKEN.safeTransfer(msg.sender, repay);
    }
}

/// @dev Never repays: used to prove the lender enforces repayment.
contract DefaultingBorrower is IFlashLoanReceiver {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external {}
}

/// @dev Repays only part of the principal.
contract PartialRepaymentBorrower is IFlashLoanReceiver {
    using SafeERC20 for MockERC20;

    MockERC20 internal immutable TOKEN;

    constructor(MockERC20 token) {
        TOKEN = token;
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata) external {
        TOKEN.safeTransfer(msg.sender, amount - 1);
    }
}

contract MockLenderTest is Test {
    MockERC20 internal token;
    MockLender internal lender;

    address internal constant PROVIDER = address(0x1111);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new MockERC20("Lender Token", "LND", 18);
        lender = new MockLender(token);

        token.mint(PROVIDER, 1_000_000e18);
        vm.startPrank(PROVIDER);
        token.approve(address(lender), type(uint256).max);
        lender.deposit(1_000_000e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_DepositCreditsProvider() public {
        token.mint(ALICE, 500e18);
        vm.prank(ALICE);
        token.approve(address(lender), 500e18);
        vm.prank(ALICE);
        lender.deposit(500e18);

        assertEq(lender.deposits(ALICE), 500e18);
        assertEq(lender.totalDeposited(), 1_000_500e18);
        assertEq(lender.maxFlashLoan(), 1_000_500e18);
    }

    function test_WithdrawReturnsTokens() public {
        vm.prank(PROVIDER);
        lender.withdraw(400e18);

        assertEq(lender.deposits(PROVIDER), 999_600e18);
        assertEq(lender.totalDeposited(), 999_600e18);
        assertEq(token.balanceOf(PROVIDER), 400e18);
    }

    function test_RevertWhen_WithdrawingMoreThanDeposited() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MockLender.InsufficientDeposit.selector, 10e18, 0));
        lender.withdraw(10e18);
    }

    /*//////////////////////////////////////////////////////////////
                          FLASH LOANS
    //////////////////////////////////////////////////////////////*/

    function test_FlashLoanHappyPath() public {
        RepayingBorrower borrower = new RepayingBorrower(lender, token);

        uint256 providerBefore = token.balanceOf(address(lender));

        vm.prank(address(borrower));
        lender.flashLoan(100_000e18, "");

        assertEq(borrower.callbackCount(), 1, "callback must fire");
        assertEq(borrower.lastAmount(), 100_000e18);
        assertEq(token.balanceOf(address(lender)), providerBefore, "lender made whole");
        assertEq(borrower.repayAmount(), 0);
        assertEq(lender.totalDeposited(), 1_000_000e18, "bookkeeping untouched");
    }

    function test_BorrowerHoldsThePrincipalDuringTheCallback() public {
        RepayingBorrower borrower = new RepayingBorrower(lender, token);

        vm.prank(address(borrower));
        lender.flashLoan(100_000e18, "");

        assertEq(borrower.balanceDuringCallback(), 100_000e18, "funds are usable mid-loan");
        assertEq(token.balanceOf(address(borrower)), 0, "and returned by the time it exits");
        assertEq(token.balanceOf(address(lender)), 1_000_000e18, "lender still whole");
    }

    function test_FeeIsZero() public {
        RepayingBorrower borrower = new RepayingBorrower(lender, token);

        vm.prank(address(borrower));
        lender.flashLoan(50_000e18, "");

        assertEq(lender.FEE(), 0);
        assertEq(borrower.lastFee(), 0);
    }

    function test_DataIsForwardedToCallback() public {
        RepayingBorrower borrower = new RepayingBorrower(lender, token);

        vm.prank(address(borrower));
        lender.flashLoan(1_000e18, hex"cafe");

        assertEq(borrower.lastData(), hex"cafe");
    }

    function test_LoanCanBeRepaidFromExternalSource() public {
        RepayingBorrower borrower = new RepayingBorrower(lender, token);
        // Repay more than the principal; the lender keeps the surplus.
        borrower.setRepayAmount(101_000e18);
        token.mint(address(borrower), 1_000e18);

        vm.prank(address(borrower));
        lender.flashLoan(100_000e18, "");

        assertEq(token.balanceOf(address(lender)), 1_001_000e18, "surplus is retained");
    }

    function test_RevertWhen_PrincipalNotRepaid() public {
        DefaultingBorrower borrower = new DefaultingBorrower();

        // The borrower keeps the 10k it was lent, so the lender comes up short.
        vm.prank(address(borrower));
        vm.expectRevert(
            abi.encodeWithSelector(
                MockLender.NotRepaid.selector, 1_000_000e18, 1_000_000e18 - 10_000e18
            )
        );
        lender.flashLoan(10_000e18, "");
    }

    /*//////////////////////////////////////////////////////////////
                            FAILURE PATHS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_LoanExceedsLiquidity() public {
        RepayingBorrower borrower = new RepayingBorrower(lender, token);

        vm.prank(address(borrower));
        vm.expectRevert(
            abi.encodeWithSelector(
                MockLender.InsufficientLiquidity.selector, 2_000_000e18, 1_000_000e18
            )
        );
        lender.flashLoan(2_000_000e18, "");
    }

    function test_RevertWhen_PartiallyRepaid() public {
        PartialRepaymentBorrower borrower = new PartialRepaymentBorrower(token);

        // The lender ends up exactly one wei short of where it started.
        vm.prank(address(borrower));
        vm.expectRevert(
            abi.encodeWithSelector(MockLender.NotRepaid.selector, 1_000_000e18, 1_000_000e18 - 1)
        );
        lender.flashLoan(10_000e18, "");
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_FlashLoanAlwaysRepaid(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        RepayingBorrower borrower = new RepayingBorrower(lender, token);

        uint256 lenderBefore = token.balanceOf(address(lender));
        uint256 depositsBefore = lender.totalDeposited();

        vm.prank(address(borrower));
        lender.flashLoan(amount, "");

        assertEq(borrower.callbackCount(), 1);
        assertEq(borrower.lastAmount(), amount);
        assertEq(token.balanceOf(address(lender)), lenderBefore, "lender must be made whole");
        assertEq(lender.totalDeposited(), depositsBefore, "deposits must not change");
    }

    function testFuzz_MaxFlashLoanTracksBalance(uint256 deposited) public {
        deposited = bound(deposited, 1, 500_000e18);

        vm.prank(BOB);
        token.approve(address(lender), type(uint256).max);
        token.mint(BOB, deposited);
        vm.prank(BOB);
        lender.deposit(deposited);

        assertEq(lender.maxFlashLoan(), 1_000_000e18 + deposited);
    }

    function testFuzz_WithdrawNeverExceedsDeposit(uint256 deposited, uint256 withdrawn) public {
        deposited = bound(deposited, 1, 100_000e18);
        withdrawn = bound(withdrawn, 1, deposited);

        token.mint(ALICE, deposited);
        vm.prank(ALICE);
        token.approve(address(lender), type(uint256).max);
        vm.prank(ALICE);
        lender.deposit(deposited);

        vm.prank(ALICE);
        lender.withdraw(withdrawn);

        assertEq(lender.deposits(ALICE), deposited - withdrawn);
        assertEq(token.balanceOf(ALICE), withdrawn);
    }
}
