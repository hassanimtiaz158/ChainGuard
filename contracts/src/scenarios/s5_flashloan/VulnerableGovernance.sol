// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGovernance} from "./IGovernance.sol";

/**
 * @title VulnerableGovernance
 * @notice Token governance that measures voting power with the caller's
 *         *current* token balance.
 * @dev BUG: {castVote} reads `token.balanceOf(msg.sender)` at the moment of the
 *      vote. A borrower can flash-loan a large balance, vote, and repay it all
 *      inside a single transaction, so the votes cost nothing but gas. The
 *      hardened contract ({SecureGovernance}) weights votes with the checkpoint
 *      fixed at the proposal snapshot instead.
 */
contract VulnerableGovernance is IGovernance {
    using SafeERC20 for ERC20;

    /// @notice Voting token.
    ERC20 public immutable token;

    /// @notice For-votes required for a proposal to pass.
    uint256 public constant QUORUM = 1_000_000 ether;

    /// @notice Length of the voting window, in blocks.
    uint256 public constant VOTING_PERIOD = 50;

    /// @inheritdoc IGovernance
    uint256 public proposalCount;

    struct Proposal {
        address proposer;
        address beneficiary;
        string description;
        uint256 snapshot;
        uint256 deadline;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        mapping(address => bool) voted;
    }

    mapping(uint256 => Proposal) private _proposals;

    error UnknownProposal();
    error VotingClosed();
    error VotingStillOpen();
    error AlreadyVoted();
    error AlreadyExecuted();
    error ZeroAddress();
    error ProposalNotSucceeded(uint256 forVotes, uint256 againstVotes);

    event Proposed(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed beneficiary,
        string description
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support);
    event Executed(uint256 indexed proposalId, address indexed beneficiary);

    /**
     * @param token_ governance token whose balances confer voting power
     */
    constructor(ERC20 token_) {
        if (address(token_) == address(0)) {
            revert ZeroAddress();
        }
        token = token_;
    }

    /// @inheritdoc IGovernance
    function propose(address beneficiary, string calldata description)
        external
        returns (uint256 proposalId)
    {
        if (beneficiary == address(0)) {
            revert ZeroAddress();
        }

        proposalId = ++proposalCount;
        Proposal storage p = _proposals[proposalId];
        p.proposer = msg.sender;
        p.beneficiary = beneficiary;
        p.description = description;
        p.snapshot = block.number;
        p.deadline = block.number + VOTING_PERIOD;

        emit Proposed(proposalId, msg.sender, beneficiary, description);
    }

    /// @inheritdoc IGovernance
    function castVote(uint256 proposalId, bool support) external {
        Proposal storage p = _proposals[proposalId];
        if (p.proposer == address(0)) {
            revert UnknownProposal();
        }
        if (block.number > p.deadline) {
            revert VotingClosed();
        }
        if (p.voted[msg.sender]) {
            revert AlreadyVoted();
        }
        p.voted[msg.sender] = true;

        emit VoteCast(proposalId, msg.sender, support);

        // BUG: weight is whatever balance the voter happens to hold right now,
        // so a flash loan inside the same transaction buys unlimited votes.
        uint256 weight = token.balanceOf(msg.sender);
        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }
    }

    /// @inheritdoc IGovernance
    function execute(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        if (p.proposer == address(0)) {
            revert UnknownProposal();
        }
        if (p.executed) {
            revert AlreadyExecuted();
        }
        if (block.number <= p.deadline) {
            revert VotingStillOpen();
        }
        if (p.forVotes < QUORUM || p.forVotes <= p.againstVotes) {
            revert ProposalNotSucceeded(p.forVotes, p.againstVotes);
        }

        p.executed = true;
        emit Executed(proposalId, p.beneficiary);
        token.safeTransfer(p.beneficiary, token.balanceOf(address(this)));
    }

    /// @inheritdoc IGovernance
    function proposalState(uint256 proposalId) external view returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];
        if (p.proposer == address(0)) {
            revert UnknownProposal();
        }
        if (p.executed) {
            return ProposalState.Executed;
        }
        if (block.number <= p.deadline) {
            return ProposalState.Active;
        }
        if (p.forVotes < QUORUM || p.forVotes <= p.againstVotes) {
            return ProposalState.Defeated;
        }
        return ProposalState.Succeeded;
    }

    /// @inheritdoc IGovernance
    function votesFor(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].forVotes;
    }

    /// @inheritdoc IGovernance
    function votesAgainst(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].againstVotes;
    }

    /// @inheritdoc IGovernance
    function snapshotBlock(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].snapshot;
    }

    /// @inheritdoc IGovernance
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _proposals[proposalId].voted[voter];
    }
}
