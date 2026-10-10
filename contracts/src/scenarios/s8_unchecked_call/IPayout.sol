// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockNonStandardERC20} from "../../common/MockNonStandardERC20.sol";

/**
 * @notice Shared interface for the payout desks in scenario S8 (unchecked
 *         external call).
 * @dev Both variants hold an ETH pool and a token pool, and pay out of either.
 *      What differs is whether the result of the external transfer is checked.
 */
interface IPayout {
    /// @notice Fund the ETH pool.
    function deposit() external payable;

    /**
     * @notice Pay `amount` of ETH to `to`.
     * @param to recipient
     * @param amount ETH to send
     */
    function payout(address payable to, uint256 amount) external;

    /**
     * @notice Pull `amount` tokens from the caller into the token pool.
     * @param amount tokens to deposit
     */
    function depositToken(uint256 amount) external;

    /**
     * @notice Pay `amount` tokens to `to`.
     * @param to recipient
     * @param amount tokens to send
     */
    function payoutToken(address to, uint256 amount) external;

    /// @notice Total ETH the desk believes it has paid out.
    function totalEthPaid() external view returns (uint256);

    /// @notice Total tokens the desk believes it has paid out.
    function totalTokenPaid() external view returns (uint256);

    /// @notice The (non-standard) token this desk pays out.
    function token() external view returns (MockNonStandardERC20);
}
