// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IQuiz} from "./IQuiz.sol";

/**
 * @title VulnerableQuiz
 * @notice Prize quiz that pays the first person to submit the correct
 *         *plaintext* answer.
 * @dev BUG: the winning answer is broadcast in the clear and sits in the
 *      mempool before it is mined. Any observer can read it, copy it, and
 *      resubmit it with a higher priority fee so that their transaction lands
 *      first and takes the prize. {SecureQuiz} avoids this by hiding the answer
 *      behind a commit-reveal scheme.
 */
contract VulnerableQuiz is IQuiz {
    /// @inheritdoc IQuiz
    bytes32 public immutable answerHash;

    /// @inheritdoc IQuiz
    uint256 public immutable prize;

    /// @inheritdoc IQuiz
    address public winner;

    /// @inheritdoc IQuiz
    bool public solved;

    error AlreadySolved();
    error WrongAnswer();
    error PayoutFailed();

    event Solved(address indexed winner, uint256 prize);

    /**
     * @param answerHash_ keccak256 hash of the correct answer
     */
    constructor(bytes32 answerHash_) payable {
        answerHash = answerHash_;
        prize = msg.value;
    }

    /// @inheritdoc IQuiz
    function submitAnswer(string calldata answer) external {
        if (solved) {
            revert AlreadySolved();
        }
        if (keccak256(bytes(answer)) != answerHash) {
            revert WrongAnswer();
        }

        solved = true;
        winner = msg.sender;
        emit Solved(msg.sender, prize);

        (bool ok,) = msg.sender.call{value: prize}("");
        if (!ok) {
            revert PayoutFailed();
        }
    }
}
