// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {MockAMM} from "../../src/common/MockAMM.sol";
import {MockERC20} from "../../src/common/MockERC20.sol";
import {MockTWAPOracle, IPriceSource} from "../../src/common/MockTWAPOracle.sol";

import {Attacker} from "../../src/scenarios/s4_oracle/Attacker.sol";
import {SecureLending} from "../../src/scenarios/s4_oracle/SecureLending.sol";
import {VulnerableLending} from "../../src/scenarios/s4_oracle/VulnerableLending.sol";

/**
 * @notice Scenario S4: oracle manipulation.
 * @dev The vulnerable pool prices collateral from the AMM spot price, so a
 *      single swap moves the loan-to-value. The secure pool consults a TWAP and
 *      rejects stale or deviating prices.
 */
contract S4OracleManipulationTest is Test {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockAMM internal amm;
    MockTWAPOracle internal oracle;

    VulnerableLending internal vulnerable;
    SecureLending internal secure;

    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    /// @notice AMM token0: the collateral token the attacker pumps.
    MockERC20 internal collateralToken;

    /// @notice AMM token1: the token lent out and spent to skew the pool.
    MockERC20 internal borrowToken;

    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 internal constant LTV_BPS = 5_000;

    /// @notice Reserve of each side of the AMM (price starts at 1.0).
    uint256 internal constant POOL_LIQUIDITY = 1_000 ether;

    /// @notice Borrow-token liquidity each lending pool can lend out.
    uint256 internal constant BORROW_LIQUIDITY = 10_000 ether;

    /// @notice Collateral the attacker seeds into the pool.
    uint256 internal constant ATTACKER_COLLATERAL = 100 ether;

    /// @notice Borrow tokens the attacker swaps in to skew the price.
    uint256 internal constant ATTACKER_SWAP = 1_000 ether;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        amm = new MockAMM(tokenA, tokenB, 30);

        collateralToken = amm.token0();
        borrowToken = amm.token1();

        oracle = new MockTWAPOracle(IPriceSource(address(amm)), 60, 10);

        vulnerable = new VulnerableLending(amm);
        secure = new SecureLending(amm, oracle);

        // Seed both sides of the AMM at 1:1 so the starting price is 1.0.
        collateralToken.mint(address(this), POOL_LIQUIDITY);
        borrowToken.mint(address(this), POOL_LIQUIDITY);
        collateralToken.approve(address(amm), type(uint256).max);
        borrowToken.approve(address(amm), type(uint256).max);
        amm.addLiquidity(POOL_LIQUIDITY, POOL_LIQUIDITY);

        // Give each lending pool real borrow-token liquidity to lend.
        borrowToken.mint(address(vulnerable), BORROW_LIQUIDITY);
        borrowToken.mint(address(secure), BORROW_LIQUIDITY);

        attackerVuln = new Attacker(address(vulnerable));
        attackerSec = new Attacker(address(secure));
    }

    /// @dev Fund an attacker with the collateral and skew capital it needs.
    function _fundAttacker(Attacker attacker) internal {
        collateralToken.mint(address(attacker), ATTACKER_COLLATERAL);
        borrowToken.mint(address(attacker), ATTACKER_SWAP);
    }

    /// @dev Record a fair-priced TWAP history so `consult` has a window.
    function _buildOracleHistory() internal {
        uint256 timestamp = vm.getBlockTimestamp();
        for (uint256 i = 0; i < 12; i++) {
            timestamp += 60;
            vm.warp(timestamp);
            oracle.update();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        THE EXPLOIT (vulnerable)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A single swap inflates the collateral value, the pool lends far
     *         past the honest LTV, and the attacker walks away in profit.
     */
    function test_exploit_succeeds_on_vulnerable() public {
        _fundAttacker(attackerVuln);

        uint256 poolBorrowBefore = borrowToken.balanceOf(address(vulnerable));

        vm.prank(address(attackerVuln));
        attackerVuln.attack();

        uint256 priceBefore = attackerVuln.priceBefore();
        uint256 priceAfter = attackerVuln.priceAfter();
        uint256 valueBefore = (ATTACKER_COLLATERAL * priceBefore) / PRICE_SCALE;
        uint256 valueAfter = (ATTACKER_COLLATERAL * priceAfter) / PRICE_SCALE;
        uint256 honestMax = (valueBefore * LTV_BPS) / 10_000;

        // Acceptance requirement: log collateral value before and after the
        // manipulation.
        console2.log("--- S4 collateral value (vulnerable) ---");
        console2.log("price before manipulation :", priceBefore);
        console2.log("price after manipulation  :", priceAfter);
        console2.log("collateral value before   :", valueBefore);
        console2.log("collateral value after    :", valueAfter);
        console2.log("honest max borrow         :", honestMax);
        console2.log("attacker borrowed         :", attackerVuln.borrowed());
        console2.log("attacker profit           :", attackerVuln.profit());

        assertGt(priceAfter, priceBefore, "spot price was skewed upward");
        assertGt(valueAfter, valueBefore, "collateral value was inflated");
        assertGt(attackerVuln.borrowed(), honestMax, "borrowed beyond the honest LTV");
        assertGt(attackerVuln.profit(), 0, "attacker should profit");

        // The pool lent real tokens against value that no longer exists.
        assertLt(
            borrowToken.balanceOf(address(vulnerable)),
            poolBorrowBefore - honestMax,
            "pool lost more than an honest loan would allow"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         THE DEFENSE (secure)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The same skew trips the secure pool's deviation guard, so the
     *         whole attack reverts and nothing moves.
     */
    function test_exploit_fails_on_secure() public {
        _buildOracleHistory();
        _fundAttacker(attackerSec);

        uint256 poolBefore = borrowToken.balanceOf(address(secure));

        vm.prank(address(attackerSec));
        vm.expectPartialRevert(SecureLending.PriceDeviation.selector);
        attackerSec.attack();

        assertEq(attackerSec.borrowed(), 0, "no borrow recorded");
        assertEq(attackerSec.profit(), 0, "no profit");
        assertEq(secure.debtOf(address(attackerSec)), 0, "no debt accrued");
        assertEq(borrowToken.balanceOf(address(secure)), poolBefore, "pool untouched");
    }

    /**
     * @notice An honest borrower at the true price is unaffected by the guards.
     */
    function test_secure_borrow_at_true_price_works() public {
        _buildOracleHistory();

        address borrower = address(0xBEEF);
        collateralToken.mint(borrower, 100 ether);

        vm.startPrank(borrower);
        collateralToken.approve(address(secure), type(uint256).max);
        secure.depositCollateral(100 ether);

        assertEq(secure.price(), PRICE_SCALE, "TWAP sits at the honest price");
        assertEq(secure.maxBorrow(borrower), 50 ether, "50% LTV at price 1.0");

        secure.borrow(40 ether);
        assertEq(secure.debtOf(borrower), 40 ether);
        assertEq(borrowToken.balanceOf(borrower), 40 ether);

        borrowToken.approve(address(secure), type(uint256).max);
        secure.repay(15 ether);
        assertEq(secure.debtOf(borrower), 25 ether, "partial repayment reduces debt");
        vm.stopPrank();
    }

    /**
     * @notice A price nobody has refreshed is refused.
     */
    function test_secure_reverts_when_oracle_stale() public {
        _buildOracleHistory();

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(SecureLending.StalePrice.selector);
        secure.price();
    }

    /*//////////////////////////////////////////////////////////////
                          NORMAL BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice On the vulnerable pool an honest borrower is still held to LTV.
     */
    function test_vulnerable_reverts_when_borrow_exceeds_ltv() public {
        address borrower = address(0xCAFE);
        collateralToken.mint(borrower, 100 ether);

        vm.startPrank(borrower);
        collateralToken.approve(address(vulnerable), type(uint256).max);
        vulnerable.depositCollateral(100 ether);

        uint256 max = vulnerable.maxBorrow(borrower);
        assertEq(max, 50 ether);

        vm.expectRevert(abi.encodeWithSelector(VulnerableLending.OverLtv.selector, 60 ether, max));
        vulnerable.borrow(60 ether);
        vm.stopPrank();
    }

    /**
     * @notice Withdraw and overpay guards behave the same on the vulnerable
     *         pool; only the oracle is different.
     */
    function test_vulnerable_repay_and_withdraw_guards() public {
        address borrower = address(0x5151);
        collateralToken.mint(borrower, 100 ether);
        borrowToken.mint(borrower, 100 ether);

        vm.startPrank(borrower);
        collateralToken.approve(address(vulnerable), type(uint256).max);
        borrowToken.approve(address(vulnerable), type(uint256).max);
        vulnerable.depositCollateral(100 ether);
        vulnerable.borrow(40 ether);

        // Withdrawing into an under-collateralised state is rejected here too.
        vm.expectRevert(
            abi.encodeWithSelector(VulnerableLending.OverLtv.selector, 40 ether, 35 ether)
        );
        vulnerable.withdrawCollateral(30 ether);

        // Overpaying only clears the debt.
        vulnerable.repay(100 ether);
        assertEq(vulnerable.debtOf(borrower), 0, "debt cleared, not negative");
        assertEq(borrowToken.balanceOf(borrower), 100 ether, "only the debt was taken");
        vm.stopPrank();
    }

    /**
     * @notice Honest deposit/borrow/repay/withdraw works on the vulnerable pool.
     */
    function test_vulnerable_honest_round_trip() public {
        address borrower = address(0x1234);
        collateralToken.mint(borrower, 100 ether);

        vm.startPrank(borrower);
        collateralToken.approve(address(vulnerable), type(uint256).max);
        vulnerable.depositCollateral(100 ether);
        assertEq(vulnerable.collateralValueOf(borrower), 100 ether);

        vulnerable.borrow(40 ether);
        assertEq(vulnerable.debtOf(borrower), 40 ether);

        borrowToken.approve(address(vulnerable), type(uint256).max);
        vulnerable.repay(40 ether);
        assertEq(vulnerable.debtOf(borrower), 0);

        vulnerable.withdrawCollateral(100 ether);
        assertEq(vulnerable.collateralOf(borrower), 0);
        assertEq(collateralToken.balanceOf(borrower), 100 ether);
        vm.stopPrank();
    }

    /**
     * @notice Collateral cannot be withdrawn into an under-collateralised state.
     */
    function test_secure_withdraw_collateral_requires_health() public {
        _buildOracleHistory();

        address borrower = address(0xB0B);
        collateralToken.mint(borrower, 100 ether);

        vm.startPrank(borrower);
        collateralToken.approve(address(secure), type(uint256).max);
        secure.depositCollateral(100 ether);
        secure.borrow(40 ether);

        // 90 collateral -> max 45 >= 40, still healthy.
        secure.withdrawCollateral(10 ether);
        assertEq(secure.collateralOf(borrower), 90 ether);
        assertEq(secure.collateralValueOf(borrower), 90 ether, "value tracks the price");
        assertEq(collateralToken.balanceOf(borrower), 10 ether);

        // 60 collateral -> max 30 < 40, rejected.
        vm.expectRevert(abi.encodeWithSelector(SecureLending.OverLtv.selector, 40 ether, 30 ether));
        secure.withdrawCollateral(30 ether);
        vm.stopPrank();
    }

    /**
     * @notice Repaying more than is owed only clears the debt.
     */
    function test_repay_caps_at_outstanding_debt() public {
        _buildOracleHistory();

        address borrower = address(0xABCD);
        collateralToken.mint(borrower, 100 ether);
        borrowToken.mint(borrower, 100 ether);

        vm.startPrank(borrower);
        collateralToken.approve(address(secure), type(uint256).max);
        borrowToken.approve(address(secure), type(uint256).max);
        secure.depositCollateral(100 ether);
        secure.borrow(40 ether);

        // Pays 40 of the 100 offered, leaving the borrower with their 100.
        secure.repay(100 ether);
        assertEq(secure.debtOf(borrower), 0, "debt cleared, not negative");
        assertEq(borrowToken.balanceOf(borrower), 100 ether, "only the debt was taken");
        vm.stopPrank();
    }

    /**
     * @notice Honest borrow/repay round trips on the secure pool.
     */
    function testFuzz_secure_borrow_repay(uint256 depositAmount, uint256 borrowAmount) public {
        _buildOracleHistory();

        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        uint256 max = (depositAmount * LTV_BPS) / 10_000;
        borrowAmount = bound(borrowAmount, 1, max);

        address borrower = address(0xF00F);
        collateralToken.mint(borrower, depositAmount);

        vm.startPrank(borrower);
        collateralToken.approve(address(secure), type(uint256).max);
        secure.depositCollateral(depositAmount);
        secure.borrow(borrowAmount);
        assertEq(secure.debtOf(borrower), borrowAmount);

        borrowToken.approve(address(secure), type(uint256).max);
        secure.repay(borrowAmount);
        assertEq(secure.debtOf(borrower), 0);
        vm.stopPrank();

        assertEq(
            borrowToken.balanceOf(address(secure)),
            BORROW_LIQUIDITY,
            "pool is made whole after repayment"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_inputsAreInvalid() public {
        vm.expectRevert(VulnerableLending.ZeroAmount.selector);
        vulnerable.depositCollateral(0);
        vm.expectRevert(VulnerableLending.ZeroAmount.selector);
        vulnerable.withdrawCollateral(0);
        vm.expectRevert(VulnerableLending.ZeroAmount.selector);
        vulnerable.borrow(0);
        vm.expectRevert(VulnerableLending.ZeroAmount.selector);
        vulnerable.repay(0);

        vm.prank(address(0xD00D));
        vm.expectRevert(
            abi.encodeWithSelector(VulnerableLending.InsufficientCollateral.selector, 1 ether, 0)
        );
        vulnerable.withdrawCollateral(1 ether);

        vm.expectRevert(SecureLending.ZeroAmount.selector);
        secure.depositCollateral(0);
        vm.expectRevert(SecureLending.ZeroAmount.selector);
        secure.withdrawCollateral(0);
        vm.expectRevert(SecureLending.ZeroAmount.selector);
        secure.borrow(0);
        vm.expectRevert(SecureLending.ZeroAmount.selector);
        secure.repay(0);

        vm.prank(address(0xD00D));
        vm.expectRevert(
            abi.encodeWithSelector(SecureLending.InsufficientCollateral.selector, 1 ether, 0)
        );
        secure.withdrawCollateral(1 ether);
    }

    function test_revertWhen_attackerHasNoSeed() public {
        vm.expectRevert(Attacker.MissingSeed.selector);
        attackerVuln.attack();

        vm.expectRevert(Attacker.MissingSeed.selector);
        attackerSec.attack();
    }

    function test_revertWhen_constructorRejectsZeroTarget() public {
        vm.expectRevert(Attacker.ZeroTarget.selector);
        new Attacker(address(0));
    }

    function test_profitIsZeroBeforeAttack() public view {
        assertEq(attackerVuln.profit(), 0);
        assertEq(attackerSec.profit(), 0);
    }
}
