// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IQuiz} from "./IQuiz.sol";

/**
 * @title SecureQuiz
 * @notice Prize quiz that replaces plaintext answers with a commit-reveal
 *         scheme.
 * @dev FIX: a solver first calls {commit} with a hash of their answer, a
 *      secret salt, and their own address, then calls {reveal} after
 *      {REVEAL_DELAY} blocks. Because the commitment hides the answer, a
 *      front-runner cannot read it; because it is bound to the committer,
 *      copying the commitment and revealing it from another account fails.
 *      Plaintext submission is disabled outright, so the S6 attack has no
 *      entry point.
 */
contract SecureQuiz is IQuiz {
    /// @inheritdoc IQuiz
    bytes32 public immutable answerHash;

    /// @inheritdoc IQuiz
    uint256 public immutable prize;

    /// @inheritdoc IQuiz
    address public winner;

    /// @inheritdoc IQuiz
    bool public solved;

    /// @notice Blocks that must pass between committing and revealing.
    uint256 public constant REVEAL_DELAY = 5;

    /// @notice Commitment per solver: keccak256(abi.encode(answer, salt, solver)).
    mapping(address => bytes32) public commitments;

    /// @notice Block at which each solver committed.
    mapping(address => uint256) public committedAt;

    error AlreadySolved();
    error PlaintextSubmissionDisabled();
    error CommitmentExists();
    error NoCommitment();
    error RevealTooEarly();
    error BadReveal();
    error WrongAnswer();
    error PayoutFailed();

    event Committed(address indexed solver, bytes32 commitment);
    event Revealed(address indexed winner, uint256 prize);

    /**
     * @param answerHash_ keccak256 hash of the correct answer
     */
    constructor(bytes32 answerHash_) payable {
        answerHash = answerHash_;
        prize = msg.value;
    }

    /// @inheritdoc IQuiz
    function submitAnswer(string calldata) external pure {
        revert PlaintextSubmissionDisabled();
    }

    /**
     * @notice Commit to an answer without revealing it.
     * @param commitment keccak256(abi.encode(answer, salt, msg.sender))
     */
    function commit(bytes32 commitment) external {
        if (solved) {
            revert AlreadySolved();
        }
        if (commitments[msg.sender] != bytes32(0)) {
            revert CommitmentExists();
        }

        commitments[msg.sender] = commitment;
        committedAt[msg.sender] = block.number;
        emit Committed(msg.sender, commitment);
    }

    /**
     * @notice Reveal a previously committed answer and claim the prize.
     * @param answer plaintext answer
     * @param salt   secret value used when committing
     */
    function reveal(string calldata answer, bytes32 salt) external {
        if (solved) {
            revert AlreadySolved();
        }

        bytes32 commitment = commitments[msg.sender];
        if (commitment == bytes32(0)) {
            revert NoCommitment();
        }
        if (block.number < committedAt[msg.sender] + REVEAL_DELAY) {
            revert RevealTooEarly();
        }
        if (keccak256(abi.encode(answer, salt, msg.sender)) != commitment) {
            revert BadReveal();
        }
        if (keccak256(bytes(answer)) != answerHash) {
            revert WrongAnswer();
        }

        solved = true;
        winner = msg.sender;
        delete commitments[msg.sender];
        emit Revealed(msg.sender, prize);

        (bool ok,) = msg.sender.call{value: prize}("");
        if (!ok) {
            revert PayoutFailed();
        }
    }
}
