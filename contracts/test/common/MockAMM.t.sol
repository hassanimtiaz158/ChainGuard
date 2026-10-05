// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockAMM} from "../../src/common/MockAMM.sol";
import {MockERC20} from "../../src/common/MockERC20.sol";

contract MockAMMTest is Test {
    MockAMM internal amm;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal constant LP = address(0x1111);
    address internal constant TRADER = address(0x2222);
    address internal constant RECIPIENT = address(0x3333);

    uint256 internal constant FEE_BPS = 30; // 0.3%
    uint256 internal constant INITIAL_LIQUIDITY = 1_000_000e18;

    function setUp() public {
        tokenA = new MockERC20("Token A", "A", 18);
        tokenB = new MockERC20("Token B", "B", 18);

        amm = new MockAMM(tokenA, tokenB, FEE_BPS);

        token0 = amm.token0();
        token1 = amm.token1();

        vm.startPrank(LP);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        token0.mint(LP, INITIAL_LIQUIDITY);
        token1.mint(LP, INITIAL_LIQUIDITY);
        amm.addLiquidity(INITIAL_LIQUIDITY, INITIAL_LIQUIDITY);
        vm.stopPrank();

        token0.mint(TRADER, 1_000_000e18);
        token1.mint(TRADER, 1_000_000e18);

        vm.startPrank(TRADER);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_TokensAreSortedByAddress() public view {
        assertTrue(address(token0) < address(token1), "token0 must be the lower address");
        assertTrue(address(amm.token0()) == address(token0));
        assertTrue(address(amm.token1()) == address(token1));
    }

    function test_FeeIsStored() public view {
        assertEq(amm.feeBps(), FEE_BPS);
    }

    /// @dev Pins both arms of the constructor sort. `setUp` only ever hits one,
    ///      because CREATE addresses are whatever they are, so the pool is
    ///      rebuilt from tokens placed at addresses of our choosing.
    function test_TokensAreSortedRegardlessOfConstructorOrder() public {
        address low = address(0xAAA1);
        address high = address(0xBBB2);
        // `vm.etch` rather than `deployCodeTo`: MockERC20 has an immutable
        // decimals field, which is only patched into the runtime code by a
        // real constructor run.
        bytes memory runtime = address(tokenA).code;
        vm.etch(low, runtime);
        vm.etch(high, runtime);

        MockAMM ascending = new MockAMM(MockERC20(low), MockERC20(high), FEE_BPS);
        assertEq(address(ascending.token0()), low, "already-ordered input stays put");
        assertEq(address(ascending.token1()), high);

        MockAMM descending = new MockAMM(MockERC20(high), MockERC20(low), FEE_BPS);
        assertEq(address(descending.token0()), low, "reversed input is swapped");
        assertEq(address(descending.token1()), high);
    }

    function test_RevertWhen_TokensAreIdentical() public {
        vm.expectRevert(MockAMM.IdenticalTokens.selector);
        new MockAMM(tokenA, tokenA, FEE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_GetReservesMirrorsTheIndividualGetters() public view {
        (uint256 reserve0_, uint256 reserve1_) = amm.getReserves();

        assertEq(reserve0_, amm.reserve0());
        assertEq(reserve1_, amm.reserve1());
        assertEq(reserve0_, INITIAL_LIQUIDITY);
        assertEq(reserve1_, INITIAL_LIQUIDITY);
    }

    function test_AddLiquidityUpdatesReserves() public {
        token0.mint(LP, 1_000e18);
        token1.mint(LP, 2_000e18);

        vm.prank(LP);
        amm.addLiquidity(1_000e18, 2_000e18);

        assertEq(amm.reserve0(), INITIAL_LIQUIDITY + 1_000e18);
        assertEq(amm.reserve1(), INITIAL_LIQUIDITY + 2_000e18);
    }

    function test_RevertWhen_AddingZeroAmount() public {
        vm.startPrank(LP);
        vm.expectRevert(MockAMM.ZeroAmount.selector);
        amm.addLiquidity(0, 1_000e18);
        vm.expectRevert(MockAMM.ZeroAmount.selector);
        amm.addLiquidity(1_000e18, 0);
        vm.stopPrank();
    }

    function test_SyncPullsReservesFromBalances() public {
        token0.mint(LP, 500e18);

        vm.prank(LP);
        token0.transfer(address(amm), 500e18);

        amm.sync();

        assertEq(amm.reserve0(), INITIAL_LIQUIDITY + 500e18);
    }

    /*//////////////////////////////////////////////////////////////
                            SPOT PRICE
    //////////////////////////////////////////////////////////////*/

    function test_GetSpotPriceIsOneForBalancedPool() public view {
        assertEq(amm.getSpotPrice(), 1e18);
    }

    function test_RevertWhen_SpotPriceOnEmptyPool() public {
        MockAMM empty = new MockAMM(tokenA, tokenB, FEE_BPS);
        vm.expectRevert(MockAMM.EmptyReserve.selector);
        empty.getSpotPrice();
    }

    function test_SpotPriceMovesWithReserves() public {
        uint256 priceBefore = amm.getSpotPrice();

        vm.prank(TRADER);
        amm.swap(1_000e18, 0, 0, TRADER);

        // Selling token0 into the pool adds token0 and removes token1, so the
        // marginal price of token0 denominated in token1 falls.
        assertLt(amm.getSpotPrice(), priceBefore);
    }

    function test_SpotPriceIsTriviallyMovableInOneBlock() public {
        // This is the S4 hazard in one assertion: 1% of the pool moves the
        // reported price by a visible amount, and nothing resists it.
        uint256 priceBefore = amm.getSpotPrice();

        vm.prank(TRADER);
        amm.swap(10_000e18, 0, 0, RECIPIENT);

        uint256 priceAfter = amm.getSpotPrice();
        assertLt(priceAfter, priceBefore);
        assertApproxEqRel(priceAfter, priceBefore * 99 / 100, 0.01e18);
    }

    /*//////////////////////////////////////////////////////////////
                                QUOTE
    //////////////////////////////////////////////////////////////*/

    function test_QuoteMatchesExecutedSwap() public {
        uint256 quoted = amm.quote(100e18, true);
        uint256 received;
        vm.prank(TRADER);
        amm.swap(100e18, 0, 0, RECIPIENT);

        received = token1.balanceOf(RECIPIENT);
        assertEq(quoted, received, "quote must match execution");
    }

    function test_QuoteReversedDirection() public view {
        uint256 quoted = amm.quote(100e18, false);
        assertGt(quoted, 0);
        assertLt(quoted, 100e18, "output must be smaller than input");
    }

    function test_RevertWhen_QuotingZero() public {
        vm.expectRevert(MockAMM.ZeroAmount.selector);
        amm.quote(0, true);
    }

    /*//////////////////////////////////////////////////////////////
                                SWAPS
    //////////////////////////////////////////////////////////////*/

    function test_SwapToken0ForToken1() public {
        uint256 amountIn = 100e18;
        uint256 reserveBefore0 = amm.reserve0();

        vm.prank(TRADER);
        uint256 amountOut = amm.swap(amountIn, 0, 0, RECIPIENT);

        assertEq(token1.balanceOf(RECIPIENT), amountOut);
        assertEq(amm.reserve0(), reserveBefore0 + amountIn);
        assertEq(amm.reserve1(), INITIAL_LIQUIDITY - amountOut);
        assertEq(amountOut, _expectedOut(amountIn, INITIAL_LIQUIDITY, INITIAL_LIQUIDITY));
        assertLt(amountOut, amountIn, "the fee means you always receive less than you put in");
    }

    function test_SwapToken1ForToken0() public {
        uint256 amountIn = 100e18;
        uint256 reserveBefore1 = amm.reserve1();

        vm.prank(TRADER);
        uint256 amountOut = amm.swap(0, amountIn, 0, RECIPIENT);

        assertEq(token0.balanceOf(RECIPIENT), amountOut);
        assertEq(amm.reserve1(), reserveBefore1 + amountIn);
        assertEq(amm.reserve0(), INITIAL_LIQUIDITY - amountOut);
        // The pool is symmetric, so the reverse direction pays out the same.
        assertEq(amountOut, _expectedOut(amountIn, INITIAL_LIQUIDITY, INITIAL_LIQUIDITY));
    }

    /// @dev Independent re-implementation of the constant-product quote, so the
    ///      swap tests pin an exact number instead of echoing `quote()`.
    function _expectedOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        view
        returns (uint256)
    {
        uint256 net = amountIn - (amountIn * FEE_BPS) / amm.BPS();
        return (net * reserveOut) / (reserveIn + net);
    }

    function test_DustSwapCostsTheTraderOneWeiAndReturnsNothing() public {
        vm.prank(TRADER);
        uint256 amountOut = amm.swap(1, 0, 0, RECIPIENT);

        assertEq(amountOut, 0, "one wei cannot buy anything at this depth");
        assertEq(amm.reserve0(), INITIAL_LIQUIDITY + 1);
        assertEq(amm.reserve1(), INITIAL_LIQUIDITY, "the output reserve is untouched");
    }

    function test_SwapAlwaysMovesReservesInOppositeDirections() public {
        uint256 r0Before = amm.reserve0();
        uint256 r1Before = amm.reserve1();

        vm.prank(TRADER);
        amm.swap(500e18, 0, 0, RECIPIENT);

        assertGt(amm.reserve0(), r0Before);
        assertLt(amm.reserve1(), r1Before);
    }

    function test_RevertWhen_BothSidesSupplied() public {
        vm.prank(TRADER);
        vm.expectRevert(MockAMM.BothSidesSupplied.selector);
        amm.swap(1e18, 1e18, 0, RECIPIENT);
    }

    function test_RevertWhen_SwappingZero() public {
        vm.prank(TRADER);
        vm.expectRevert(MockAMM.ZeroAmount.selector);
        amm.swap(0, 0, 0, RECIPIENT);
    }

    /*//////////////////////////////////////////////////////////////
                       SLIPPAGE PROTECTION (S6)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_MinOutNotMet() public {
        uint256 amountIn = 100e18;
        uint256 available = amm.quote(amountIn, true);

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(MockAMM.InsufficientOutput.selector, amountIn, available)
        );
        amm.swap(amountIn, 0, amountIn, RECIPIENT);
    }

    function test_RevertWhen_MinOutNotMetReversed() public {
        uint256 amountIn = 100e18;
        uint256 available = amm.quote(amountIn, true);

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(MockAMM.InsufficientOutput.selector, amountIn, available)
        );
        amm.swap(0, amountIn, amountIn, RECIPIENT);
    }

    function test_SlippageGuardPassesWhenSatisfied() public {
        uint256 quoted = amm.quote(100e18, true);

        vm.prank(TRADER);
        uint256 amountOut = amm.swap(100e18, 0, 99e18, RECIPIENT);

        assertEq(amountOut, quoted);
        assertGe(amountOut, 99e18);
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ConstantProductNeverShrinks(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 100_000e18);

        uint256 kBefore = amm.reserve0() * amm.reserve1();
        uint256 r0Before = amm.reserve0();
        uint256 r1Before = amm.reserve1();

        vm.prank(TRADER);
        amm.swap(amountIn, 0, 0, RECIPIENT);

        uint256 kAfter = amm.reserve0() * amm.reserve1();
        assertGe(kAfter, kBefore, "constant product must not decrease");

        assertEq(amm.reserve0(), r0Before + amountIn);
        assertGt(amm.reserve1(), 0, "pool keeps a positive reserve");
        // Non-strict: a dust trade can round the output down to zero, leaving
        // reserve1 unchanged (see test_DustSwapCostsTheTraderOneWei...).
        assertLe(amm.reserve1(), r1Before, "the output reserve is drawn down, never up");
    }

    function testFuzz_PriceImpactGrowsWithTradeSize(uint256 smallIn, uint256 largeIn) public view {
        smallIn = bound(smallIn, 1e18, 1_000e18);
        largeIn = bound(largeIn, 5_000e18, 50_000e18);

        uint256 smallOut = amm.quote(smallIn, true);
        uint256 largeOut = amm.quote(largeIn, true);

        uint256 smallRate = (smallOut * 1e18) / smallIn;
        uint256 largeRate = (largeOut * 1e18) / largeIn;

        assertLt(largeRate, smallRate, "bigger trades get worse rates");
    }

    function testFuzz_ConstantProductNeverShrinksReverseDirection(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 100_000e18);

        uint256 kBefore = amm.reserve0() * amm.reserve1();
        uint256 r1Before = amm.reserve1();

        vm.prank(TRADER);
        amm.swap(0, amountIn, 0, RECIPIENT);

        assertGe(amm.reserve0() * amm.reserve1(), kBefore);
        assertEq(amm.reserve1(), r1Before + amountIn);
    }
}
