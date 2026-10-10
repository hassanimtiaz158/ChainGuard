// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVault} from "./IVault.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SecureVault
 * @notice ETH vault hardened against reentrancy.
 * @dev FIX: enforces the Checks-Effects-Interactions (CEI) pattern *and*
 *      gates external-calling methods behind OpenZeppelin's ReentrancyGuard.
 *      It deliberately has no `receive()`: unsolicited ETH is rejected so the
 *      contract's real balance can only ever change through deposit/withdraw,
 *      which keeps the ledger invariant airtight.
 */
contract SecureVault is IVault, ReentrancyGuard {
    mapping(address => uint256) public balanceOf;

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

    function withdraw() external override nonReentrant {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) {
            revert InsufficientBalance();
        }

        // CEI: effects (state change) come first.
        balanceOf[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);

        // CEI: interactions happen only after effects. The guard is now armed,
        // so any re-entry from the recipient reverts here.
        (bool success, bytes memory returndata) = msg.sender.call{value: amount}("");

        // Bubble the recipient's revert reason up rather than masking it with a
        // generic error. A re-entrant call therefore surfaces the real cause,
        // `ReentrancyGuardReentrantCall`, instead of an opaque payment failure.
        if (!success) {
            if (returndata.length == 0) {
                revert TransferFailed();
            }
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    error ZeroDeposit();
    error InsufficientBalance();
    error TransferFailed();
}
