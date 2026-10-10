// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRewardToken} from "./IRewardToken.sol";

/**
 * @title VulnerableToken
 * @notice Accounting token with an unchecked subtraction and a
 *         divide-before-multiply reward formula (SWC-101 / SWC-101-adjacent).
 * @dev BUG 1 — {transfer} performs the balance subtraction inside an
 *      `unchecked` block. A transfer larger than the sender's balance wraps
 *      around to a near-`2**256` balance instead of reverting, so the sum of
 *      all balances can exceed {totalSupply}. The attacker mints itself an
 *      enormous balance out of nothing.
 *
 *      BUG 2 — {pendingReward} divides before multiplying. Integer division
 *      truncates first, so a member's share is usually reported as zero even
 *      when the pool is large enough to pay something.
 */
contract VulnerableToken is IRewardToken {
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
     * @dev BUG 1: subtraction inside `unchecked`, so an over-transfer
     *      underflows instead of reverting.
     */
    function transfer(address to, uint256 amount) external override returns (bool) {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        // The unchecked subtraction is the vulnerability this scenario teaches.
        unchecked {
            balanceOf[msg.sender] -= amount;
        }
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
     * @dev BUG 2: divides before multiplying, truncating shares to zero.
     */
    function pendingReward(address account) public view override returns (uint256) {
        if (totalSupply == 0) {
            return 0;
        }
        // forge-lint: disable-next-line(divide-before-multiply)
        return (rewardPool / totalSupply) * balanceOf[account];
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
