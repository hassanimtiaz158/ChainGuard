// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

import {MockLender} from "../../src/common/MockLender.sol";

import {Attacker} from "../../src/scenarios/s5_flashloan/Attacker.sol";
import {GovernanceToken} from "../../src/scenarios/s5_flashloan/GovernanceToken.sol";
import {IGovernance} from "../../src/scenarios/s5_flashloan/IGovernance.sol";
import {SecureGovernance} from "../../src/scenarios/s5_flashloan/SecureGovernance.sol";
import {VulnerableGovernance} from "../../src/scenarios/s5_flashloan/VulnerableGovernance.sol";

/**
 * @notice Scenario S5: flash-loan governance attack.
 * @dev The vulnerable governance weights votes by the caller's live token
 *      balance, so a flash loan bought and repaid inside one transaction swings
 *      the vote. The secure governance weights votes by the checkpoint recorded
 *      at the proposal snapshot, where the attacker held nothing.
 */
contract S5FlashLoanGovernanceTest is Test {
    GovernanceToken internal token;
    MockLender internal lender;

    VulnerableGovernance internal vulnerable;
    SecureGovernance internal secure;

    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    /// @notice Tokens held by each governance as its treasury.
    uint256 internal constant TREASURY = 5_000_000 ether;

    /// @notice Liquidity the flash lender can advance.
    uint256 internal constant LENDER_LIQUIDITY = 3_000_000 ether;

    /// @notice Voting window, in blocks (must match the contracts).
    uint256 internal constant VOTING_PERIOD = 50;

    address internal constant PROPOSER = address(0x1234);

    function setUp() public {
        token = new GovernanceToken();

        vulnerable = new VulnerableGovernance(token);
        secure = new SecureGovernance(token);

        token.mint(address(vulnerable), TREASURY);
        token.mint(address(secure), TREASURY);

        lender = new MockLender(token);
        token.mint(address(lender), LENDER_LIQUIDITY);

        attackerVuln = new Attacker(address(vulnerable), address(lender));
        attackerSec = new Attacker(address(secure), address(lender));
    }

    /*//////////////////////////////////////////////////////////////
                        THE EXPLOIT (vulnerable)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A flash loan buys enough votes to pass a treasury-draining
     *         proposal, and it is repaid in the same transaction.
     */
    function test_exploit_succeeds_on_vulnerable() public {
        vm.prank(PROPOSER);
        uint256 pid = vulnerable.propose(address(attackerVuln), "drain the treasury");
        uint256 snapshot = vulnerable.snapshotBlock(pid);

        vm.roll(vm.getBlockNumber() + 1);

        uint256 lenderBefore = token.balanceOf(address(lender));

        attackerVuln.attack();

        // The borrowed balance was counted as voting power...
        assertEq(vulnerable.votesFor(pid), LENDER_LIQUIDITY, "flash-loaned votes counted");
        assertTrue(vulnerable.hasVoted(pid, address(attackerVuln)), "vote recorded");
        // ...and the loan is already repaid, so the attacker holds nothing.
        assertEq(token.balanceOf(address(lender)), lenderBefore, "loan repaid in the same tx");
        assertEq(token.balanceOf(address(attackerVuln)), 0, "no free tokens retained");

        // Close voting, execute, and watch the treasury move.
        assertEq(vulnerable.snapshotBlock(pid), snapshot, "snapshot is the proposal block");
        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        assertEq(uint8(vulnerable.proposalState(pid)), uint8(IGovernance.ProposalState.Succeeded));
        vulnerable.execute(pid);

        assertEq(attackerVuln.profit(), TREASURY, "attacker drained the treasury");
        assertEq(token.balanceOf(address(vulnerable)), 0, "treasury emptied");
        assertEq(uint8(vulnerable.proposalState(pid)), uint8(IGovernance.ProposalState.Executed));
    }

    /*//////////////////////////////////////////////////////////////
                         THE DEFENSE (secure)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The very same flash-loan vote is worth nothing at the snapshot,
     *         so the proposal is defeated and the treasury stays put.
     */
    function test_exploit_fails_on_secure() public {
        vm.prank(PROPOSER);
        uint256 pid = secure.propose(address(attackerSec), "drain the treasury");

        vm.roll(vm.getBlockNumber() + 1);
        attackerSec.attack();

        assertEq(secure.votesFor(pid), 0, "flash-loaned tokens carry no snapshot votes");
        assertTrue(secure.hasVoted(pid, address(attackerSec)), "vote was recorded, just weightless");
        assertEq(token.balanceOf(address(attackerSec)), 0);

        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        assertEq(uint8(secure.proposalState(pid)), uint8(IGovernance.ProposalState.Defeated));
        vm.expectRevert(
            abi.encodeWithSelector(SecureGovernance.ProposalNotSucceeded.selector, 0, 0)
        );
        secure.execute(pid);

        assertEq(attackerSec.profit(), 0, "nothing extracted");
        assertEq(token.balanceOf(address(secure)), TREASURY, "treasury intact");
    }

    /**
     * @notice A holder who already had (and delegated) tokens before the
     *         snapshot keeps full voting power.
     */
    function test_secure_accepts_honest_snapshot_votes() public {
        address honest = makeAddr("honest");
        token.mint(honest, 2_000_000 ether);
        vm.prank(honest);
        token.delegate(honest);

        vm.prank(honest);
        uint256 pid = secure.propose(honest, "honest proposal");

        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(honest);
        secure.castVote(pid, true);
        assertEq(secure.votesFor(pid), 2_000_000 ether, "pre-existing holder's votes count");

        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        secure.execute(pid);
        assertEq(token.balanceOf(honest), 2_000_000 ether + TREASURY, "beneficiary paid");
    }

    /**
     * @notice A quorum-sized tie is still defeated: equal for/against does not
     *         pass.
     */
    function test_secure_tieIsDefeated() public {
        address voterA = makeAddr("voterA");
        address voterB = makeAddr("voterB");
        token.mint(voterA, 1_000_000 ether);
        token.mint(voterB, 1_000_000 ether);
        vm.prank(voterA);
        token.delegate(voterA);
        vm.prank(voterB);
        token.delegate(voterB);

        vm.prank(voterA);
        uint256 pid = secure.propose(voterA, "tie");

        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(voterA);
        secure.castVote(pid, true);
        vm.prank(voterB);
        secure.castVote(pid, false);

        assertEq(secure.votesFor(pid), 1_000_000 ether);
        assertEq(secure.votesAgainst(pid), 1_000_000 ether);

        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecureGovernance.ProposalNotSucceeded.selector, 1_000_000 ether, 1_000_000 ether
            )
        );
        secure.execute(pid);
    }

    /**
     * @notice Full lifecycle on the secure governance, including the
     *         single-execution guard.
     */
    function test_secure_proposalLifecycle() public {
        address voter = makeAddr("lifecycleVoter");
        token.mint(voter, 2_000_000 ether);
        vm.prank(voter);
        token.delegate(voter);

        vm.prank(voter);
        uint256 pid = secure.propose(voter, "lifecycle");
        assertEq(secure.snapshotBlock(pid), vm.getBlockNumber(), "snapshot is the proposal block");
        assertEq(uint8(secure.proposalState(pid)), uint8(IGovernance.ProposalState.Active));

        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(voter);
        secure.castVote(pid, true);

        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        assertEq(uint8(secure.proposalState(pid)), uint8(IGovernance.ProposalState.Succeeded));

        secure.execute(pid);
        assertEq(uint8(secure.proposalState(pid)), uint8(IGovernance.ProposalState.Executed));

        vm.expectRevert(SecureGovernance.AlreadyExecuted.selector);
        secure.execute(pid);
    }

    /*//////////////////////////////////////////////////////////////
                           NORMAL BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Honest live-balance voting works on the vulnerable governance too.
     */
    function test_vulnerable_accepts_honest_votes() public {
        address honest = makeAddr("honest");
        token.mint(honest, 2_000_000 ether);

        vm.prank(honest);
        uint256 pid = vulnerable.propose(honest, "honest proposal");

        vm.prank(honest);
        vulnerable.castVote(pid, true);
        assertEq(vulnerable.votesFor(pid), 2_000_000 ether);

        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        vulnerable.execute(pid);
        assertEq(token.balanceOf(honest), 2_000_000 ether + TREASURY);
    }

    /**
     * @notice Votes against are tallied and can defeat a proposal.
     */
    function test_votesAgainstAreCounted() public {
        address voter = makeAddr("contrarian");
        token.mint(voter, 3_000_000 ether);

        vm.prank(voter);
        uint256 pid = vulnerable.propose(voter, "contentious proposal");

        vm.prank(voter);
        vulnerable.castVote(pid, false);

        assertEq(vulnerable.votesAgainst(pid), 3_000_000 ether);
        assertEq(vulnerable.votesFor(pid), 0);

        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                VulnerableGovernance.ProposalNotSucceeded.selector, 0, 3_000_000 ether
            )
        );
        vulnerable.execute(pid);
    }

    function test_proposalCountTracksProposals() public {
        assertEq(vulnerable.proposalCount(), 0);
        vm.prank(PROPOSER);
        uint256 first = vulnerable.propose(PROPOSER, "one");
        vm.prank(PROPOSER);
        uint256 second = vulnerable.propose(PROPOSER, "two");
        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(vulnerable.proposalCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                            INPUT / STATE GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_votingOnUnknownProposal() public {
        vm.expectRevert(VulnerableGovernance.UnknownProposal.selector);
        vulnerable.castVote(1, true);
        vm.expectRevert(SecureGovernance.UnknownProposal.selector);
        secure.castVote(1, true);

        vm.expectRevert(VulnerableGovernance.UnknownProposal.selector);
        vulnerable.proposalState(1);
        vm.expectRevert(SecureGovernance.UnknownProposal.selector);
        secure.proposalState(1);
    }

    function test_revertWhen_votingAfterDeadline() public {
        vm.prank(PROPOSER);
        uint256 pid = vulnerable.propose(PROPOSER, "late");
        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        vm.expectRevert(VulnerableGovernance.VotingClosed.selector);
        vulnerable.castVote(pid, true);

        vm.prank(PROPOSER);
        uint256 sid = secure.propose(PROPOSER, "late");
        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        vm.expectRevert(SecureGovernance.VotingClosed.selector);
        secure.castVote(sid, true);
    }

    function test_revertWhen_doubleVoting() public {
        vm.prank(PROPOSER);
        uint256 pid = vulnerable.propose(PROPOSER, "double");
        vm.prank(PROPOSER);
        vulnerable.castVote(pid, true);
        vm.prank(PROPOSER);
        vm.expectRevert(VulnerableGovernance.AlreadyVoted.selector);
        vulnerable.castVote(pid, true);

        vm.prank(PROPOSER);
        uint256 sid = secure.propose(PROPOSER, "double");
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(PROPOSER);
        secure.castVote(sid, true);
        vm.prank(PROPOSER);
        vm.expectRevert(SecureGovernance.AlreadyVoted.selector);
        secure.castVote(sid, true);
    }

    function test_revertWhen_executingBeforeDeadline() public {
        vm.prank(PROPOSER);
        uint256 pid = vulnerable.propose(PROPOSER, "early");
        vm.expectRevert(VulnerableGovernance.VotingStillOpen.selector);
        vulnerable.execute(pid);

        vm.prank(PROPOSER);
        uint256 sid = secure.propose(PROPOSER, "early");
        vm.expectRevert(SecureGovernance.VotingStillOpen.selector);
        secure.execute(sid);
    }

    function test_revertWhen_executingTwice() public {
        address voter = makeAddr("voter");
        token.mint(voter, 2_000_000 ether);

        vm.prank(voter);
        uint256 pid = vulnerable.propose(voter, "twice");
        vm.prank(voter);
        vulnerable.castVote(pid, true);

        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
        vulnerable.execute(pid);

        vm.expectRevert(VulnerableGovernance.AlreadyExecuted.selector);
        vulnerable.execute(pid);
    }

    function test_revertWhen_proposingZeroBeneficiary() public {
        vm.expectRevert(VulnerableGovernance.ZeroAddress.selector);
        vulnerable.propose(address(0), "x");
        vm.expectRevert(SecureGovernance.ZeroAddress.selector);
        secure.propose(address(0), "x");
    }

    function test_revertWhen_constructorRejectsZeroToken() public {
        vm.expectRevert(VulnerableGovernance.ZeroAddress.selector);
        new VulnerableGovernance(ERC20(address(0)));
        vm.expectRevert(SecureGovernance.ZeroAddress.selector);
        new SecureGovernance(ERC20Votes(address(0)));
    }

    function test_revertWhen_attackerRejectsZeroAddresses() public {
        vm.expectRevert(Attacker.ZeroAddress.selector);
        new Attacker(address(0), address(lender));
        vm.expectRevert(Attacker.ZeroAddress.selector);
        new Attacker(address(vulnerable), address(0));
    }

    function test_revertWhen_flashLoanCallbackFromStranger() public {
        vm.expectRevert(Attacker.NotLender.selector);
        attackerVuln.onFlashLoan(address(0), address(token), 1, 0, abi.encode(uint256(1)));
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_vulnerableWeightsByLiveBalance(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        address voter = makeAddr("fuzzVoter");
        token.mint(voter, amount);

        vm.prank(voter);
        uint256 pid = vulnerable.propose(voter, "fuzz");
        vm.prank(voter);
        vulnerable.castVote(pid, true);

        assertEq(vulnerable.votesFor(pid), amount, "weight equals the live balance");
    }
}
