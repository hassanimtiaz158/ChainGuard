// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Shared interface for the reward tokens in scenario S3
 *         (integer and rounding logic).
 * @dev Both variants are simple accounting tokens with a reward pool. What
 *      differs is whether balance arithmetic is checked and whether the reward
 *      share is computed with multiply-before-divide.
 */
interface IRewardToken {
    /// @notice Token balance of `account`.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Total minted tokens.
    function totalSupply() external view returns (uint256);

    /// @notice Tokens set aside for reward distribution.
    function rewardPool() external view returns (uint256);

    /// @notice Mint `amount` tokens to `to` (lab-only, permissionless).
    function mint(address to, uint256 amount) external;

    /// @notice Move `amount` tokens from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Move `amount` tokens from the caller into the reward pool.
    function fundRewards(uint256 amount) external;

    /// @notice Reward currently owed to `account`.
    function pendingReward(address account) external view returns (uint256);

    /// @notice Pay the caller its pending reward.
    function claim() external returns (uint256 reward);
}
