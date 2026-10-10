// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Shared interface for the wallets in scenario S2 (access control).
 * @dev Both variants expose the same surface so the run engine can drive them
 *      generically: the attacker always starts by calling {setOwner} and then
 *      {sweep}. What differs is whether {setOwner} is authorised.
 */
interface IWallet {
    /// @notice Current administrator of the wallet.
    function owner() external view returns (address);

    /**
     * @notice Replace the administrator.
     * @param newOwner address that becomes the new owner
     */
    function setOwner(address newOwner) external;

    /// @notice Deposit ETH, credited to the caller's internal balance.
    function deposit() external payable;

    /// @notice Withdraw all ETH credited to the caller.
    function withdraw() external;

    /// @notice Internal ETH balance of `user`.
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Send the wallet's entire ETH balance to `to`.
     * @param to recipient of the funds
     */
    function sweep(address payable to) external;

    /**
     * @notice Emergency drain, intended for the owner only.
     * @param to recipient of the funds
     */
    function emergencyWithdraw(address payable to) external;
}
