// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGovernance} from "./IGovernance.sol";

/**
 * @title SecureGovernance
 * @notice Token governance that weights votes with the checkpoint fixed at the
 *         proposal snapshot.
 * @dev FIX: {castVote} asks the token for {Votes-getPastVotes} at the block the
 *      proposal was created. Tokens acquired *after* that block — including
 *      flash-loaned tokens held only for the duration of the vote — carry no
 *      weight, so buying votes this way is impossible. Honest holders who
 *      already had tokens (and delegated them) at the snapshot keep their
 *      full voting power.
 */
contract SecureGovernance is IGovernance {
    using SafeERC20 for ERC20Votes;

    /// @notice Voting token exposing historical checkpoints.
    ERC20Votes private immutable _token;

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
     * @param token_ governance token exposing vote checkpoints
     */
    constructor(ERC20Votes token_) {
        if (address(token_) == address(0)) {
            revert ZeroAddress();
        }
        _token = token_;
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

        // FIX: weight is fixed at the proposal snapshot, so tokens acquired
        // afterwards (a flash loan) contribute nothing.
        uint256 weight = _token.getPastVotes(msg.sender, p.snapshot);
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
        _token.safeTransfer(p.beneficiary, _token.balanceOf(address(this)));
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
