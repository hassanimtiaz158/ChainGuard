// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Anything that can report an instantaneous price, e.g. {MockAMM}.
 * @dev The returned value is expected to be scaled by 1e18.
 */
interface IPriceSource {
    function getSpotPrice() external view returns (uint256);
}

/**
 * @title MockTWAPOracle
 * @notice Time-weighted average price oracle over an {IPriceSource}, used by the
 *         hardened lending contract in the oracle-manipulation scenario (S4).
 *
 * @dev How it defends against manipulation
 *      - `consult()` averages the source price over a window of whole
 *        intervals, so a single-block reserve skew cannot move the reported
 *        price by very much: it would have to sustain the skewed price for the
 *        whole averaging window.
 *      - `updatedAt()` lets callers enforce a staleness bound and reject a
 *        price nobody has refreshed recently.
 *
 *      Mechanics follow the Uniswap V2 oracle: each {update} stores a
 *      cumulative `price * elapsed_time` value, and the average over any
 *      interval is the difference of two cumulative readings divided by the
 *      elapsed time between them. That makes an arbitrary historical average
 *      cheap rather than iterating over samples.
 *
 *      Caveat, matching real TWAP oracles: the caller chooses the averaging
 *      window. A wider window resists manipulation better but reacts more
 *      slowly to genuine price moves.
 */
contract MockTWAPOracle {
    /// @notice A recorded cumulative-price checkpoint.
    struct Observation {
        uint32 timestamp;
        uint256 priceCumulative;
    }

    /// @notice Instantaneous price source, typically a {MockAMM}.
    IPriceSource public immutable source;

    /// @notice Minimum spacing (in seconds) between stored observations.
    uint32 public immutable interval;

    /// @notice Number of intervals retained for historical queries.
    uint32 public immutable window;

    /// @notice Cumulative-price checkpoints, oldest first.
    Observation[] public observations;

    error ZeroInterval();
    error ZeroWindow();
    error ZeroPeriods();
    error NoObservations();
    error InsufficientHistory(uint256 requestedSpan, uint256 availableSpan);

    event Updated(uint32 indexed timestamp, uint256 priceCumulative);

    /**
     * @param source_   instantaneous price source
     * @param interval_ minimum seconds between observations
     * @param window_   how many intervals of history to retain
     */
    constructor(IPriceSource source_, uint32 interval_, uint32 window_) {
        if (interval_ == 0) {
            revert ZeroInterval();
        }
        if (window_ == 0) {
            revert ZeroWindow();
        }
        source = source_;
        interval = interval_;
        window = window_;
    }

    /// @notice Number of stored observations.
    function observationsCount() external view returns (uint256) {
        return observations.length;
    }

    /// @notice The current instantaneous price from the source.
    function latestAnswer() public view returns (uint256) {
        return source.getSpotPrice();
    }

    /// @notice Timestamp of the newest observation, or 0 if never updated.
    function updatedAt() public view returns (uint256) {
        if (observations.length == 0) {
            return 0;
        }
        return observations[observations.length - 1].timestamp;
    }

    /// @notice Seconds elapsed since the newest observation.
    function secondsSinceUpdate() public view returns (uint256) {
        uint256 last = updatedAt();
        if (last == 0) {
            return 0;
        }
        return block.timestamp - last;
    }

    /**
     * @notice Whether the newest observation is older than `maxAge` seconds.
     * @dev Returns true when the oracle has never been updated. A TWAP oracle
     *      must compare against block.timestamp somewhere; the tiny validator
     *      drift that permits is irrelevant next to a multi-interval window.
     */
    function isStale(uint256 maxAge) public view returns (bool) {
        uint256 last = updatedAt();
        if (last == 0) {
            return true;
        }
        // A TWAP oracle must compare against block.timestamp somewhere; the tiny
        // validator drift that permits is irrelevant next to a multi-interval window.
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp - last > maxAge;
    }

    /**
     * @notice Record the current source price as a cumulative checkpoint.
     * @dev Permissionless: anyone may call this to keep the oracle fresh.
     *      Repeated calls in the same block overwrite the last checkpoint rather
     *      than adding a zero-length interval.
     * @return priceCumulative the new cumulative reading
     * @return price          the instantaneous price used for this update
     */
    function update() public returns (uint256 priceCumulative, uint256 price) {
        // Safe: block.timestamp is a uint256 that stays under 2**32 for roughly
        // 136 years, so this cannot truncate for any realistic deployment.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 nowTs = uint32(block.timestamp);
        price = source.getSpotPrice();

        uint256 length = observations.length;
        uint256 cumulative;
        uint32 lastTimestamp = 0;

        if (length == 0) {
            // Seed on the current time; the offset cancels out in differences.
            cumulative = price * nowTs;
        } else {
            Observation memory last = observations[length - 1];
            lastTimestamp = last.timestamp;
            cumulative = last.priceCumulative;
            if (nowTs != lastTimestamp) {
                cumulative += price * (uint256(nowTs) - uint256(lastTimestamp));
            }
        }

        if (length > 0 && lastTimestamp == nowTs) {
            observations[length - 1].priceCumulative = cumulative;
        } else {
            observations.push(Observation({timestamp: nowTs, priceCumulative: cumulative}));
        }

        _prune();
        emit Updated(nowTs, cumulative);
        return (cumulative, price);
    }

    /**
     * @notice Time-weighted average price over the last `numPeriods` intervals.
     * @dev Reverts when the oracle has not been updated, or when it lacks
     *      history for the full requested window. When the earliest stored
     *      observation is older than the requested window the average simply
     *      spans the longer period that is actually covered.
     * @param numPeriods averaging window, in {interval} units
     * @return averagePrice time-weighted average, in the source's own scale
     */
    function consult(uint32 numPeriods) public view returns (uint256 averagePrice) {
        if (numPeriods == 0) {
            revert ZeroPeriods();
        }

        uint256 length = observations.length;
        if (length == 0) {
            revert NoObservations();
        }

        Observation memory latest = observations[length - 1];

        uint256 span = uint256(interval) * uint256(numPeriods);
        uint256 latestTimestamp = uint256(latest.timestamp);
        if (latestTimestamp <= span) {
            revert InsufficientHistory(span, latestTimestamp);
        }

        // Safe: `latestTimestamp` is a stored uint32 and `span` was checked
        // above, so the subtraction is non-negative and below 2**32.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 target = uint32(latestTimestamp - span);
        Observation memory prior = observations[_observationAtOrBefore(target)];

        uint256 elapsed = latestTimestamp - uint256(prior.timestamp);
        if (elapsed == 0) {
            revert InsufficientHistory(span, elapsed);
        }

        return (latest.priceCumulative - prior.priceCumulative) / elapsed;
    }

    /// @dev Drop checkpoints that fall outside the retained window.
    function _prune() internal {
        // Always called after a push, so at least one observation exists.
        uint256 span = uint256(interval) * (uint256(window) + 1);
        uint256 latestTimestamp = uint256(observations[observations.length - 1].timestamp);
        uint256 cutoff = latestTimestamp > span ? latestTimestamp - span : 0;

        // Shift out the oldest entry only while the next one is *still* older
        // than the cutoff, because the next one then makes a better anchor.
        // The loop stops with exactly one observation older than `cutoff` (the
        // "pivot" a full-width consult needs) plus every observation at or
        // after it, so the retained history stays bounded.
        while (observations.length > 1 && uint256(observations[1].timestamp) < cutoff) {
            for (uint256 i = 0; i < observations.length - 1; i++) {
                observations[i] = observations[i + 1];
            }
            observations.pop();
        }
    }

    /// @dev Index of the newest observation with `timestamp <= target`.
    function _observationAtOrBefore(uint32 target) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = observations.length - 1;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (uint256(observations[mid].timestamp) <= uint256(target)) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low;
    }
}
