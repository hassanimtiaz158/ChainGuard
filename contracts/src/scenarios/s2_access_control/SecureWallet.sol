// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWallet} from "./IWallet.sol";

/**
 * @title SecureWallet
 * @notice The S2 wallet with correct access control.
 * @dev FIX: inherits OpenZeppelin {Ownable}. Every privileged entry point is
 *      `onlyOwner`, and ownership can only change through the owner calling
 *      {setOwner}, which forwards to `_transferOwnership`. Authorisation is
 *      always `msg.sender`, never `tx.origin`, so a contract the owner calls
 *      does not inherit the owner's rights.
 */
contract SecureWallet is IWallet, Ownable {
    /// @inheritdoc IWallet
    mapping(address => uint256) public balanceOf;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IWallet
    function owner() public view override(IWallet, Ownable) returns (address) {
        return super.owner();
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
     * @dev FIX: only the current owner may hand over ownership.
     */
    function setOwner(address newOwner) external override onlyOwner {
        // `_transferOwnership` also rejects the zero address; this makes the
        // requirement explicit at the boundary.
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(newOwner);
    }

    /// @inheritdoc IWallet
    function sweep(address payable to) external override onlyOwner {
        if (to == address(0)) {
            revert ZeroAddress();
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
     * @dev FIX: `onlyOwner` compares `msg.sender`, so a phishing contract
     *      called by the owner cannot use the owner's authority.
     */
    function emergencyWithdraw(address payable to) external override onlyOwner {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        uint256 amount = address(this).balance;
        emit Swept(to, amount);
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool success,) = to.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    error InsufficientBalance();
    error TransferFailed();
    error ZeroAddress();
}
