// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockAMM} from "../../common/MockAMM.sol";
import {MockERC20} from "../../common/MockERC20.sol";

/**
 * @title VulnerableSwap
 * @notice Thin swap-router example over {MockAMM} with no slippage protection.
 * @dev BUG: {swapExactInput} accepts any price the pool happens to offer. A
 *      front-runner can move the pool immediately before the victim's trade, so
 *      the victim settles at a far worse rate. {SecureSwap} requires the caller
 *      to state a `minOut` and a `deadline`.
 */
contract VulnerableSwap {
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
     * @notice Sell `amountIn` of {tokenIn} for {tokenOut}, sent to the caller.
     * @dev BUG: no `minOut` and no `deadline`, so any price is accepted.
     */
    function swapExactInput(uint256 amountIn) external returns (uint256 amountOut) {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenIn.forceApprove(address(amm), amountIn);

        amountOut = amm.swap(_token0In ? amountIn : 0, _token0In ? 0 : amountIn, 0, msg.sender);

        tokenIn.forceApprove(address(amm), 0);
    }
}
