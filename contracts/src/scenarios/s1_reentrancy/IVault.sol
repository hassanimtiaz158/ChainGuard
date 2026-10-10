// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Shared interface for the ETH vaults in scenario S1 (reentrancy).
 */
interface IVault {
    /**
     * @notice Deposit ETH into the vault, crediting the caller's balance.
     */
    function deposit() external payable;

    /**
     * @notice Withdraw all ETH currently credited to the caller.
     */
    function withdraw() external;

    /**
     * @notice Get the caller's internal balance inside the vault.
     * @param user address to query
     * @return amount of ETH the user is entitled to withdraw
     */
    function balanceOf(address user) external view returns (uint256);
}
