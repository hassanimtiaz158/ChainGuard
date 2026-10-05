// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockAMM
 * @notice Minimal constant-product liquidity pool (`x * y = k`) over two
 *         MockERC20 tokens, used by the oracle-manipulation (S4), flash-loan
 *         (S5) and front-running/slippage (S6) scenarios.
 *
 * @dev Design notes
 *      - Tokens are sorted by address in the constructor, matching the
 *        Uniswap convention, so `token0`/`token1` are deterministic no matter
 *        which order the deployer passes them in.
 *      - `getSpotPrice()` reports the marginal price of token0 in token1,
 *        scaled by 1e18. It is trivially movable within a single block, which
 *        is precisely the weakness S4 exploits and the reason the hardened
 *        lending pool must use a TWAP instead.
 *      - `swap` takes an explicit `minAmountOut` so the secure S6 variant can
 *        demonstrate slippage protection; passing 0 disables the check.
 *      - No reentrancy guard: the only tokens involved are MockERC20 instances
 *        that follow the standard ERC20 rules. The hardened scenario contracts
 *        are where reentrancy defences belong.
 */
contract MockAMM {
    /// @notice Basis-point denominator (100% = 10_000).
    uint256 public constant BPS = 10_000;

    /// @notice Fixed-point scale used by {getSpotPrice}.
    uint256 public constant PRICE_SCALE = 1e18;

    // Token movements go through SafeERC20 so a false-returning token can never
    // be silently credited. This is the same discipline the hardened scenarios
    // are meant to demonstrate (S8), applied to the lab's own plumbing.
    using SafeERC20 for MockERC20;

    /// @notice Lower of the two pooled tokens, sorted by address.
    MockERC20 public immutable token0;

    /// @notice Higher of the two pooled tokens, sorted by address.
    MockERC20 public immutable token1;

    /// @notice Swap fee in basis points.
    uint256 public immutable feeBps;

    /// @notice Reserve of {token0}.
    uint256 public reserve0;

    /// @notice Reserve of {token1}.
    uint256 public reserve1;

    error IdenticalTokens();
    error ZeroAmount();
    error BothSidesSupplied();
    error InsufficientOutput(uint256 minAmountOut, uint256 amountOut);
    error EmptyReserve();

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1);
    event Swap(address indexed trader, uint256 amountIn, uint256 amountOut, bool token0In);

    /**
     * @param tokenA_  one of the tokens to pool
     * @param tokenB_  the other token to pool
     * @param feeBps_  swap fee in basis points (e.g. 30 for 0.3%)
     */
    constructor(MockERC20 tokenA_, MockERC20 tokenB_, uint256 feeBps_) {
        if (address(tokenA_) == address(tokenB_)) {
            revert IdenticalTokens();
        }
        if (address(tokenA_) < address(tokenB_)) {
            token0 = tokenA_;
            token1 = tokenB_;
        } else {
            token0 = tokenB_;
            token1 = tokenA_;
        }
        feeBps = feeBps_;
    }

    /**
     * @notice Current reserves as a pair.
     * @return reserve0_ reserve of {token0}
     * @return reserve1_ reserve of {token1}
     */
    function getReserves() public view returns (uint256 reserve0_, uint256 reserve1_) {
        return (reserve0, reserve1);
    }

    /**
     * @notice Marginal price of token0 denominated in token1, scaled by 1e18.
     * @dev Reverts when the pool is empty. Safe to read inside a transaction,
     *      which is exactly the S4 problem: it reflects the current block only.
     */
    function getSpotPrice() public view returns (uint256) {
        if (reserve0 == 0) {
            revert EmptyReserve();
        }
        return (reserve1 * PRICE_SCALE) / reserve0;
    }

    /**
     * @notice Deposit both sides of the pool at the current ratio.
     * @param amount0 tokens of {token0} to add
     * @param amount1 tokens of {token1} to add
     */
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        if (amount0 == 0 || amount1 == 0) {
            revert ZeroAmount();
        }
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        reserve0 += amount0;
        reserve1 += amount1;

        emit LiquidityAdded(msg.sender, amount0, amount1);
    }

    /**
     * @notice Quote an exact-input swap without executing it.
     * @param amountIn input amount, denominated in whichever token is supplied
     * @param token0In whether the input is {token0}
     */
    function quote(uint256 amountIn, bool token0In) public view returns (uint256 amountOut) {
        if (amountIn == 0) {
            revert ZeroAmount();
        }
        if (token0In) {
            return _amountOut(amountIn, reserve0, reserve1);
        }
        return _amountOut(amountIn, reserve1, reserve0);
    }

    /**
     * @notice Swap an exact amount of one token for the other.
     * @param amount0In    input amount of {token0} (mutually exclusive with `amount1In`)
     * @param amount1In    input amount of {token1} (mutually exclusive with `amount0In`)
     * @param minAmountOut slippage guard; the swap reverts below this output
     * @param to           recipient of the output token
     * @return amountOut   amount of the output token sent to `to`
     */
    function swap(uint256 amount0In, uint256 amount1In, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut)
    {
        if (amount0In > 0 && amount1In > 0) {
            revert BothSidesSupplied();
        }
        uint256 amountIn = amount0In > 0 ? amount0In : amount1In;
        if (amountIn == 0) {
            revert ZeroAmount();
        }

        if (amount0In > 0) {
            amountOut = _amountOut(amountIn, reserve0, reserve1);
            if (amountOut < minAmountOut) {
                revert InsufficientOutput(minAmountOut, amountOut);
            }

            token0.safeTransferFrom(msg.sender, address(this), amount0In);
            reserve0 += amount0In;
            reserve1 -= amountOut;
            token1.safeTransfer(to, amountOut);

            emit Swap(msg.sender, amount0In, amountOut, true);
        } else {
            amountOut = _amountOut(amountIn, reserve1, reserve0);
            if (amountOut < minAmountOut) {
                revert InsufficientOutput(minAmountOut, amountOut);
            }

            token1.safeTransferFrom(msg.sender, address(this), amount1In);
            reserve1 += amount1In;
            reserve0 -= amountOut;
            token0.safeTransfer(to, amountOut);

            emit Swap(msg.sender, amount1In, amountOut, false);
        }
    }

    /**
     * @notice Pull reserves back into line with the actual token balances.
     * @dev Useful after transferring tokens to the pool directly.
     */
    function sync() external {
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));
    }

    /// @dev Constant-product output with the fee taken off the input.
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        view
        returns (uint256)
    {
        // Take the fee off the top rather than scaling the whole input down, so
        // the multiplication happens before the division (see S3).
        uint256 fee = (amountIn * feeBps) / BPS;
        uint256 amountInAfterFee = amountIn - fee;
        uint256 numerator = amountInAfterFee * reserveOut;
        uint256 denominator = reserveIn + amountInAfterFee;
        return numerator / denominator;
    }
}
