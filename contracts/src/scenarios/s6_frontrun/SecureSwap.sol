// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockAMM} from "../../common/MockAMM.sol";
import {MockERC20} from "../../common/MockERC20.sol";

/**
 * @title SecureSwap
 * @notice Thin swap-router example over {MockAMM} with slippage protection.
 * @dev FIX: the caller passes a minimum acceptable output (`minOut`) and a
 *      `deadline`. If a front-runner moves the pool first, the trade either
 *      reverts inside the AMM (`InsufficientOutput`) or is refused as stale
 *      (`DeadlineExpired`), instead of silently settling at a bad price.
 */
contract SecureSwap {
    using SafeERC20 for MockERC20;

    /// @notice Pool the router trades against.
    MockAMM public immutable amm;

    /// @notice Token sold by the router.
    MockERC20 public immutable tokenIn;

    /// @notice Token bought by the router.
    MockERC20 public immutable tokenOut;

    /// @dev Whether {tokenIn} is the pool's `token0`.
    bool private immutable _token0In;

    error ZeroAddress();
    error DeadlineExpired();

    /**
     * @param amm_     constant-product pool
     * @param tokenIn_ token the caller sells
     * @param tokenOut_ token the caller buys
     */
    constructor(MockAMM amm_, MockERC20 tokenIn_, MockERC20 tokenOut_) {
        if (
            address(amm_) == address(0) || address(tokenIn_) == address(0)
                || address(tokenOut_) == address(0)
        ) {
            revert ZeroAddress();
        }
        amm = amm_;
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        _token0In = address(tokenIn_) == address(amm_.token0());
    }

    /**
     * @notice Sell `amountIn` of {tokenIn} for at least `minOut` of {tokenOut}.
     * @param amountIn amount sold
     * @param minOut   minimum acceptable output; the AMM reverts below it
     * @param deadline last timestamp at which the trade is valid
     */
    function swapExactInput(uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 amountOut)
    {
        // A swap deadline is the canonical safe use of block.timestamp: a miner
        // can only nudge it by seconds, and the caller's `minOut` is the real
        // protection.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenIn.forceApprove(address(amm), amountIn);

        amountOut = amm.swap(_token0In ? amountIn : 0, _token0In ? 0 : amountIn, minOut, msg.sender);

        tokenIn.forceApprove(address(amm), 0);
    }
}
