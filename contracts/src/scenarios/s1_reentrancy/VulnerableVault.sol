// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVault} from "./IVault.sol";

/**
 * @title VulnerableVault
 * @notice ETH vault that is vulnerable to reentrancy.
 * @dev BUG: the contract sends ETH to the caller *before* updating their
 *      internal balance. This violates Checks-Effects-Interactions. An
 *      attacker can re-enter via their receive() and withdraw again while
 *      the recorded balance is still unchanged.
 */
contract VulnerableVault is IVault {
    mapping(address => uint256) public balanceOf;

    /**
     * @notice Tracks how much ETH was initially seeded into the lab.
     * @dev Not used by exploit logic, kept for trace clarity.
     */
    uint256 public totalDeposited;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function deposit() external payable override {
        if (msg.value == 0) {
            revert ZeroDeposit();
        }
        balanceOf[msg.sender] += msg.value;
        totalDeposited += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw() external override {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) {
            revert InsufficientBalance();
        }

        // BUG: send ETH to the caller BEFORE decrementing their balance. The
        // lint warning below is the vulnerability this scenario demonstrates,
        // so it is asserted here rather than fixed.
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }

        // The state update should have happened *before* the external call.
        balanceOf[msg.sender] = 0;
        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdrawn(msg.sender, amount);
    }

    error ZeroDeposit();
    error InsufficientBalance();
    error TransferFailed();
}
