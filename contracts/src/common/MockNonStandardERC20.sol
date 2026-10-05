// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockNonStandardERC20
 * @notice Emulates the pre-ERC20-convention tokens (Tether being the canonical
 *         example) whose `transfer`/`transferFrom` return `false` on failure
 *         instead of reverting.
 *
 * @dev This is the S8 fixture. A payout contract that ignores the returned
 *      boolean will record the payment as successful while no tokens move --
 *      exactly the "unchecked external call" bug the scenario teaches. The
 *      hardened variant wraps these calls in OpenZeppelin `SafeERC20`, which
 *      reverts instead.
 *
 *      Note that `transfer` reverting is deliberately NOT how this token
 *      behaves: the return value is what callers must check.
 */
contract MockNonStandardERC20 is MockERC20 {
    bool private _transferFails;
    bool private _transferFromFails;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        MockERC20(name_, symbol_, decimals_)
    {}

    /// @notice Make `transfer` return false without moving any tokens.
    function setTransferFails(bool fails) external {
        _transferFails = fails;
    }

    /// @notice Make `transferFrom` return false without moving any tokens.
    function setTransferFromFails(bool fails) external {
        _transferFromFails = fails;
    }

    /// @notice Whether `transfer` is currently configured to return false.
    function transferFails() external view returns (bool) {
        return _transferFails;
    }

    /// @notice Whether `transferFrom` is currently configured to return false.
    function transferFromFails() external view returns (bool) {
        return _transferFromFails;
    }

    /// @notice Returns false instead of reverting when configured to fail.
    function transfer(address to, uint256 value) public override returns (bool) {
        if (_transferFails) {
            return false;
        }
        return super.transfer(to, value);
    }

    /// @notice Returns false instead of reverting when configured to fail.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (_transferFromFails) {
            return false;
        }
        return super.transferFrom(from, to, value);
    }
}
