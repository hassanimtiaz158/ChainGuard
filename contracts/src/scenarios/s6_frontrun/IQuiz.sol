// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Shared interface for the mock prize quizzes in scenario S6
 *         (front-running).
 * @dev `VulnerableQuiz` accepts a plaintext answer and pays the first correct
 *      submission; `SecureQuiz` disables plaintext submission entirely and
 *      requires a commit-reveal exchange instead.
 */
interface IQuiz {
    /**
     * @notice Submit a plaintext answer to the quiz.
     * @dev Reverts on {VulnerableQuiz} once solved and always reverts on
     *      {SecureQuiz}, which only accepts answers through commit-reveal.
     */
    function submitAnswer(string calldata answer) external;

    /// @notice Hash of the correct answer.
    function answerHash() external view returns (bytes32);

    /// @notice ETH paid to the first correct solver.
    function prize() external view returns (uint256);

    /// @notice Address that solved the quiz, or zero while unsolved.
    function winner() external view returns (address);

    /// @notice Whether the quiz has been solved.
    function solved() external view returns (bool);
}
