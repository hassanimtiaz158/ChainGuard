// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Shared interface for the collateralised lending pools in scenario S4
 *         (oracle manipulation).
 * @dev `VulnerableLending` and `SecureLending` differ only in how {price} is
 *      sourced: the vulnerable pool reads the AMM spot price directly, while
 *      the secure pool reads a TWAP with staleness and deviation guards. The
 *      rest of the surface is identical so the engine can drive either one.
 */
interface ILending {
    /**
     * @notice Deposit `amount` collateral tokens, crediting the caller.
     */
    function depositCollateral(uint256 amount) external;

    /**
     * @notice Withdraw `amount` collateral tokens, leaving the caller solvent.
     */
    function withdrawCollateral(uint256 amount) external;

    /**
     * @notice Borrow `amount` borrow tokens against the caller's collateral.
     */
    function borrow(uint256 amount) external;

    /**
     * @notice Repay `amount` of the caller's borrow-token debt.
     */
    function repay(uint256 amount) external;

    /**
     * @notice Collateral deposited by `user`.
     */
    function collateralOf(address user) external view returns (uint256);

    /**
     * @notice Borrow debt owed by `user`.
     */
    function debtOf(address user) external view returns (uint256);

    /**
     * @notice Oracle value, in borrow tokens, of `user`'s collateral.
     */
    function collateralValueOf(address user) external view returns (uint256);

    /**
     * @notice Largest debt `user` may carry at the current price.
     */
    function maxBorrow(address user) external view returns (uint256);

    /**
     * @notice Price of one collateral token, in borrow tokens, scaled by 1e18.
     */
    function price() external view returns (uint256);

    /**
     * @notice Address of the AMM the pool prices collateral from.
     */
    function amm() external view returns (address);
}
