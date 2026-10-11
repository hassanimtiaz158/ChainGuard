// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Shared interface for the mock token-governance contracts in scenario
 *         S5 (flash-loan governance attack).
 * @dev `VulnerableGovernance` weights votes by the caller's live balance, while
 *      `SecureGovernance` weights them by a checkpoint taken at the proposal
 *      snapshot. The lifecycle, quorum and execution logic are identical so the
 *      engine can drive either one the same way.
 */
interface IGovernance {
    /**
     * @notice Lifecycle of a proposal.
     * @dev `Active` while the voting window is open, then `Succeeded` or
     *      `Defeated` once it closes, and `Executed` after a successful call to
     *      {execute}.
     */
    enum ProposalState {
        Active,
        Defeated,
        Succeeded,
        Executed
    }

    /**
     * @notice Open a proposal that pays the governance treasury to `beneficiary`
     *         if it succeeds.
     * @param beneficiary address that would receive the treasury
     * @param description human-readable description of the proposal
     * @return proposalId identifier of the new proposal
     */
    function propose(address beneficiary, string calldata description)
        external
        returns (uint256 proposalId);

    /**
     * @notice Cast a vote on an open proposal.
     */
    function castVote(uint256 proposalId, bool support) external;

    /**
     * @notice Execute a successful proposal, paying its beneficiary.
     */
    function execute(uint256 proposalId) external;

    /**
     * @notice Current lifecycle state of a proposal.
     */
    function proposalState(uint256 proposalId) external view returns (ProposalState);

    /**
     * @notice Votes cast in favour of a proposal.
     */
    function votesFor(uint256 proposalId) external view returns (uint256);

    /**
     * @notice Votes cast against a proposal.
     */
    function votesAgainst(uint256 proposalId) external view returns (uint256);

    /**
     * @notice Block at which a proposal's voting weights are fixed.
     */
    function snapshotBlock(uint256 proposalId) external view returns (uint256);

    /**
     * @notice Whether `voter` has already voted on a proposal.
     */
    function hasVoted(uint256 proposalId, address voter) external view returns (bool);

    /**
     * @notice Number of proposals opened so far.
     */
    function proposalCount() external view returns (uint256);
}
