// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IWallet} from "./IWallet.sol";

/**
 * @title VulnerableWallet
 * @notice ETH wallet with two classic access-control bugs (SWC-105 / SWC-115).
 * @dev BUG 1 — unprotected ownership transfer. {setOwner} has no access control
 *      at all, so any address can make itself the administrator and then call
 *      the owner-only {sweep}.
 *
 *      BUG 2 — authorisation by `tx.origin`. {emergencyWithdraw} compares
 *      `tx.origin` to the owner instead of `msg.sender`. A contract that the
 *      real owner calls then inherits the owner's authority, so a phishing
 *      contract can drain the wallet in the owner's own transaction.
 */
contract VulnerableWallet is IWallet {
    /// @inheritdoc IWallet
    address public owner;

    /// @inheritdoc IWallet
    mapping(address => uint256) public balanceOf;

    event OwnerChanged(address indexed previousOwner, address indexed newOwner);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    /// @inheritdoc IWallet
    function deposit() external payable override {
        balanceOf[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @inheritdoc IWallet
    function withdraw() external override {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) {
            revert InsufficientBalance();
        }
        balanceOf[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    /**
     * @inheritdoc IWallet
     * @dev BUG 1: no `onlyOwner` modifier and no `msg.sender` check, so anyone
     *      can seize the wallet.
     */
    function setOwner(address newOwner) external override {
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @inheritdoc IWallet
     * @dev Authorised with `msg.sender`, which is correct; the damage comes
     *      from the unguarded {setOwner} above.
     */
    function sweep(address payable to) external override {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (msg.sender != owner) {
            revert NotOwner();
        }
        uint256 amount = address(this).balance;
        emit Swept(to, amount);
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool success,) = to.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    /**
     * @inheritdoc IWallet
     * @dev BUG 2: checks `tx.origin`, which stays the owner even when an
     *      untrusted contract is the direct caller.
     */
    function emergencyWithdraw(address payable to) external override {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        // This `tx.origin` check is the vulnerability this scenario teaches, so
        // it is asserted here rather than fixed.
        // forge-lint: disable-next-line(tx-origin, arbitrary-send-eth)
        if (tx.origin != owner) {
            revert NotOwner();
        }
        uint256 amount = address(this).balance;
        emit Swept(to, amount);
        // forge-lint: disable-next-line(reentrancy-eth, arbitrary-send-eth)
        (bool success,) = to.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    error InsufficientBalance();
    error TransferFailed();
    error NotOwner();
    error ZeroAddress();
}
