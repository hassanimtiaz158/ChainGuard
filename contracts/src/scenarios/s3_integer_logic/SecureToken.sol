// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRewardToken} from "./IRewardToken.sol";

/**
 * @title SecureToken
 * @notice The S3 token with checked arithmetic and a precise reward formula.
 * @dev FIX 1 — {transfer} relies on Solidity 0.8 checked math: an over-transfer
 *      reverts with a Panic(0x11) arithmetic error instead of wrapping. The sum
 *      of all balances therefore can never exceed {totalSupply}.
 *
 *      FIX 2 — {pendingReward} multiplies before dividing, so the share is
 *      computed with full precision and only the final result is truncated.
 */
contract SecureToken is IRewardToken {
    /// @inheritdoc IRewardToken
    mapping(address => uint256) public balanceOf;

    /// @inheritdoc IRewardToken
    uint256 public totalSupply;

    /// @inheritdoc IRewardToken
    uint256 public rewardPool;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Minted(address indexed to, uint256 amount);
    event Funded(address indexed from, uint256 amount);
    event Claimed(address indexed account, uint256 reward);

    /// @inheritdoc IRewardToken
    function mint(address to, uint256 amount) external override {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Minted(to, amount);
    }

    /**
     * @inheritdoc IRewardToken
     * @dev FIX 1: checked subtraction reverts on underflow.
     */
    function transfer(address to, uint256 amount) external override returns (bool) {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc IRewardToken
    function fundRewards(uint256 amount) external override {
        if (amount == 0) {
            revert ZeroAmount();
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[address(this)] += amount;
        rewardPool += amount;
        emit Funded(msg.sender, amount);
    }

    /**
     * @inheritdoc IRewardToken
     * @dev FIX 2: multiply before dividing to keep precision.
     */
    function pendingReward(address account) public view override returns (uint256) {
        if (totalSupply == 0) {
            return 0;
        }
        return (rewardPool * balanceOf[account]) / totalSupply;
    }

    /// @inheritdoc IRewardToken
    function claim() external override returns (uint256 reward) {
        reward = pendingReward(msg.sender);
        rewardPool -= reward;
        balanceOf[address(this)] -= reward;
        balanceOf[msg.sender] += reward;
        emit Claimed(msg.sender, reward);
    }

    error ZeroAddress();
    error ZeroAmount();
}
