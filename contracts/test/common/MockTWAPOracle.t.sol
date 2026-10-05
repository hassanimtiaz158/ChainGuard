// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPriceSource, MockTWAPOracle} from "../../src/common/MockTWAPOracle.sol";

/// @dev Settable price source so TWAP arithmetic can be checked exactly.
contract StubPriceSource is IPriceSource {
    uint256 internal price;

    constructor(uint256 price_) {
        price = price_;
    }

    function getSpotPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }
}

contract MockTWAPOracleTest is Test {
    StubPriceSource internal source;
    MockTWAPOracle internal oracle;

    uint32 internal constant INTERVAL = 60;
    uint32 internal constant WINDOW = 3;

    uint256 internal constant START_TIME = 1_000_000;

    function setUp() public {
        source = new StubPriceSource(1e18);
        oracle = new MockTWAPOracle(IPriceSource(address(source)), INTERVAL, WINDOW);
        vm.warp(START_TIME);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_ConfigIsStored() public view {
        assertEq(address(oracle.source()), address(source));
        assertEq(oracle.interval(), INTERVAL);
        assertEq(oracle.window(), WINDOW);
    }

    function test_RevertWhen_IntervalIsZero() public {
        vm.expectRevert(MockTWAPOracle.ZeroInterval.selector);
        new MockTWAPOracle(IPriceSource(address(source)), 0, WINDOW);
    }

    function test_RevertWhen_WindowIsZero() public {
        vm.expectRevert(MockTWAPOracle.ZeroWindow.selector);
        new MockTWAPOracle(IPriceSource(address(source)), INTERVAL, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          FRESH ORACLE
    //////////////////////////////////////////////////////////////*/

    function test_UpdatedAtIsZeroBeforeFirstUpdate() public view {
        assertEq(oracle.updatedAt(), 0);
        assertEq(oracle.observationsCount(), 0);
    }

    function test_SecondsSinceUpdateIsZeroBeforeFirstUpdate() public view {
        assertEq(oracle.secondsSinceUpdate(), 0);
    }

    function test_IsStaleBeforeAnyUpdate() public view {
        assertTrue(oracle.isStale(1_000), "never-updated oracle must read as stale");
    }

    function test_RevertWhen_ConsultWithoutObservations() public {
        vm.expectRevert(MockTWAPOracle.NoObservations.selector);
        oracle.consult(1);
    }

    /*//////////////////////////////////////////////////////////////
                              UPDATES
    //////////////////////////////////////////////////////////////*/

    function test_LatestAnswerMirrorsSource() public {
        source.setPrice(3.5e18);
        assertEq(oracle.latestAnswer(), 3.5e18);
    }

    function test_UpdateRecordsObservation() public {
        source.setPrice(2e18);

        (uint256 cumulative, uint256 price) = oracle.update();

        assertEq(price, 2e18);
        assertEq(cumulative, 2e18 * block.timestamp);
        assertEq(oracle.observationsCount(), 1);
        assertEq(oracle.updatedAt(), block.timestamp);

        (uint32 ts, uint256 stored) = oracle.observations(0);
        assertEq(ts, block.timestamp);
        assertEq(stored, cumulative);
    }

    function test_UpdateAccumulatesAcrossIntervals() public {
        source.setPrice(2e18);
        (uint256 firstCumulative,) = oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(4e18);
        (uint256 secondCumulative,) = oracle.update();

        assertEq(firstCumulative, 2e18 * START_TIME, "seeded as price * timestamp");
        // The second reading is the first plus price * elapsed.
        assertEq(
            secondCumulative - firstCumulative, 4e18 * uint256(INTERVAL), "one interval accrued"
        );
    }

    function test_RevertWhen_ChainIsYoungerThanTheRequestedSpan() public {
        MockTWAPOracle young = new MockTWAPOracle(IPriceSource(address(source)), INTERVAL, WINDOW);

        // A chain only half a minute old cannot answer a one-minute question.
        vm.warp(30);
        source.setPrice(1e18);
        young.update();

        vm.expectRevert(
            abi.encodeWithSelector(
                MockTWAPOracle.InsufficientHistory.selector, uint256(INTERVAL), 30
            )
        );
        young.consult(1);
    }

    function test_PruneKeepsEverythingBeforeTheWindowCanExpire() public {
        MockTWAPOracle young = new MockTWAPOracle(IPriceSource(address(source)), INTERVAL, WINDOW);

        for (uint256 i = 0; i < 3; i++) {
            vm.warp(10 + i * 10);
            young.update();
        }

        // The retained span is 60 * (3 + 1) == 240s and the chain is 30s old,
        // so nothing has aged out yet.
        assertEq(young.observationsCount(), 3);
    }

    function test_SameBlockUpdateOverwrites() public {
        source.setPrice(2e18);
        oracle.update();

        source.setPrice(9e18);
        oracle.update();

        assertEq(oracle.observationsCount(), 1, "no zero-length interval may be stored");
    }

    function test_SecondsSinceUpdateTracksClock() public {
        oracle.update();

        vm.warp(block.timestamp + 45);
        assertEq(oracle.secondsSinceUpdate(), 45);
    }

    function test_IsStaleHonoursMaxAge() public {
        oracle.update();
        assertFalse(oracle.isStale(INTERVAL), "fresh update");

        vm.warp(block.timestamp + INTERVAL + 1);
        assertTrue(oracle.isStale(INTERVAL), "older than the bound");
    }

    function test_IsStaleIsFalseExactlyAtMaxAge() public {
        oracle.update();

        vm.warp(block.timestamp + INTERVAL);
        assertFalse(oracle.isStale(INTERVAL), "boundary is not yet stale");
    }

    /*//////////////////////////////////////////////////////////////
                          CONSULT (TWAP)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ConsultZeroPeriods() public {
        oracle.update();

        vm.expectRevert(MockTWAPOracle.ZeroPeriods.selector);
        oracle.consult(0);
    }

    function test_RevertWhen_HistoryTooShort() public {
        oracle.update();

        // Only one observation exists, so a one-interval window has no anchor.
        vm.expectRevert(
            abi.encodeWithSelector(MockTWAPOracle.InsufficientHistory.selector, INTERVAL, 0)
        );
        oracle.consult(1);
    }

    /// @dev Each interval is priced by the observation at its *end*, so two
    ///      observations give one priced interval, not two.
    function test_ConsultWithOnlyOnePricedIntervalReturnsThatInterval() public {
        source.setPrice(2e18);
        oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(4e18);
        oracle.update();

        // There is only one interval of history to average, so a wider request
        // narrows to what actually exists rather than inventing a value.
        assertEq(oracle.consult(2), 4e18);
        assertEq(oracle.consult(3), 4e18);
    }

    function test_ConsultAveragesTwoIntervals() public {
        source.setPrice(2e18);
        oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(4e18);
        oracle.update();

        vm.warp(START_TIME + 2 * INTERVAL);
        source.setPrice(6e18);
        oracle.update();

        // Two priced intervals: (4 + 6) / 2.
        assertEq(oracle.consult(2), 5e18);
    }

    function test_ConsultWeightsByTimeNotSampleCount() public {
        source.setPrice(1e18);
        oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(1e18);
        oracle.update();

        vm.warp(START_TIME + 2 * INTERVAL);
        source.setPrice(1e18);
        oracle.update();

        vm.warp(START_TIME + 3 * INTERVAL);
        source.setPrice(4e18);
        oracle.update();

        // Three priced intervals of 60s each: (1 + 1 + 4) / 3 == 2e18.
        // A naive mean over the four samples would have reported 1.75e18.
        assertEq(oracle.consult(3), 2e18);
        // A one-interval window still tracks the newest price.
        assertEq(oracle.consult(1), 4e18);
    }

    function test_ConsultOverSingleIntervalReturnsLatestPrice() public {
        source.setPrice(1e18);
        oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(3e18);
        oracle.update();

        assertEq(oracle.consult(1), 3e18);
    }

    /*//////////////////////////////////////////////////////////////
                    MANIPULATION RESISTANCE (scenario S4)
    //////////////////////////////////////////////////////////////*/

    function test_UnrecordedSpotManipulationDoesNotMoveTheTwap() public {
        source.setPrice(2e18);
        oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(2e18);
        oracle.update();

        // The attacker skews the pool but never checkpoints the oracle.
        vm.warp(START_TIME + 2 * INTERVAL);
        source.setPrice(200e18);

        assertEq(oracle.latestAnswer(), 200e18, "the spot price is attacker-controlled");
        assertEq(oracle.consult(1), 2e18, "the TWAP ignores an unrecorded skew entirely");
    }

    function test_RecordedManipulationIsDilutedAcrossTheWindow() public {
        source.setPrice(2e18);
        oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(2e18);
        oracle.update();

        vm.warp(START_TIME + 2 * INTERVAL);
        source.setPrice(2e18);
        oracle.update();

        // The attacker sustains the skew long enough for one checkpoint to land.
        vm.warp(START_TIME + 3 * INTERVAL);
        source.setPrice(200e18);
        oracle.update();

        // consult(1) is fully manipulable...
        assertEq(oracle.consult(1), 200e18);
        // ...consult(3) dilutes the single skewed interval: (2 + 2 + 200) / 3.
        assertEq(oracle.consult(3), 68e18);
        assertLt(oracle.consult(3), oracle.latestAnswer());
    }

    /*//////////////////////////////////////////////////////////////
                          PRUNING
    //////////////////////////////////////////////////////////////*/

    function test_PruneBoundsHistoryGrowth() public {
        uint256 start = START_TIME;

        // Feed updates far beyond the retained window.
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(start + i * INTERVAL);
            oracle.update();
        }

        assertLt(oracle.observationsCount(), 10, "history must be bounded");
        assertEq(
            oracle.observationsCount(), 6, "one pivot older than the cutoff, plus the last window"
        );
    }

    function test_PruneKeepsConsultableHistory() public {
        uint256 start = START_TIME;

        for (uint256 i = 0; i < 8; i++) {
            vm.warp(start + i * INTERVAL);
            source.setPrice(1e18 + i * 1e18);
            oracle.update();
        }

        // A full-window consult must still resolve after pruning.
        uint256 twap = oracle.consult(WINDOW);
        assertGt(twap, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ConsultStaysBetweenMinAndMaxPrice(uint256 priceA, uint256 priceB) public {
        priceA = bound(priceA, 1e6, 1e24);
        priceB = bound(priceB, 1e6, 1e24);

        source.setPrice(priceA);
        oracle.update();

        vm.warp(START_TIME + INTERVAL);
        source.setPrice(priceB);
        oracle.update();

        uint256 average = oracle.consult(2);
        uint256 lower = priceA < priceB ? priceA : priceB;
        uint256 upper = priceA < priceB ? priceB : priceA;

        assertGe(average, lower - 1, "TWAP must not fall below the lowest price");
        assertLe(average, upper + 1, "TWAP must not exceed the highest price");
    }

    function testFuzz_UpdatedAtAlwaysTracksLastUpdate(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 10_000);
        oracle.update();

        vm.warp(block.timestamp + elapsed);

        assertEq(oracle.updatedAt(), START_TIME);
        assertEq(oracle.secondsSinceUpdate(), elapsed);
    }
}
