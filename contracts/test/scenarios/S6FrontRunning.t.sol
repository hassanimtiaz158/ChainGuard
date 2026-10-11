// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockAMM} from "../../src/common/MockAMM.sol";
import {MockERC20} from "../../src/common/MockERC20.sol";

import {Attacker} from "../../src/scenarios/s6_frontrun/Attacker.sol";
import {IQuiz} from "../../src/scenarios/s6_frontrun/IQuiz.sol";
import {SecureQuiz} from "../../src/scenarios/s6_frontrun/SecureQuiz.sol";
import {SecureSwap} from "../../src/scenarios/s6_frontrun/SecureSwap.sol";
import {VulnerableQuiz} from "../../src/scenarios/s6_frontrun/VulnerableQuiz.sol";
import {VulnerableSwap} from "../../src/scenarios/s6_frontrun/VulnerableSwap.sol";

/// @dev A contract with no receive/fallback, so ETH payouts to it revert.
contract RejectingSolver {
    function solve(IQuiz quiz, string calldata answer) external {
        quiz.submitAnswer(answer);
    }

    function commit(SecureQuiz quiz, bytes32 commitment) external {
        quiz.commit(commitment);
    }

    function reveal(SecureQuiz quiz, string calldata answer, bytes32 salt) external {
        quiz.reveal(answer, salt);
    }

    function deployAttacker(address target) external returns (Attacker) {
        return new Attacker(target);
    }
}

/**
 * @notice Scenario S6: front-running.
 * @dev Two demonstrations in one suite:
 *      1. A quiz whose plaintext answer can be copied from the mempool and
 *         submitted first, versus a commit-reveal quiz that hides it.
 *      2. A swap router that accepts any price, versus one that enforces a
 *         `minOut` and a `deadline`. Ordering is modelled explicitly with
 *         `vm.prank` — the attacker's transaction is executed before the
 *         victim's.
 */
contract S6FrontRunningTest is Test {
    string internal constant ANSWER = "satoshi";
    bytes32 internal constant ANSWER_HASH = keccak256("satoshi");
    uint256 internal constant PRIZE = 5 ether;

    VulnerableQuiz internal vulnerableQuiz;
    SecureQuiz internal secureQuiz;
    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    MockAMM internal amm;
    MockERC20 internal token0;
    MockERC20 internal token1;
    VulnerableSwap internal vulnerableSwap;
    SecureSwap internal secureSwap;

    address internal victim;
    address internal frontRunner;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 100 ether);

        vulnerableQuiz = new VulnerableQuiz{value: PRIZE}(ANSWER_HASH);
        secureQuiz = new SecureQuiz{value: PRIZE}(ANSWER_HASH);
        attackerVuln = new Attacker(address(vulnerableQuiz));
        attackerSec = new Attacker(address(secureQuiz));

        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);
        amm = new MockAMM(tokenA, tokenB, 30);
        token0 = amm.token0();
        token1 = amm.token1();

        token0.mint(address(this), 1_000 ether);
        token1.mint(address(this), 1_000 ether);
        token0.approve(address(amm), 1_000 ether);
        token1.approve(address(amm), 1_000 ether);
        amm.addLiquidity(1_000 ether, 1_000 ether);

        vulnerableSwap = new VulnerableSwap(amm, token0, token1);
        secureSwap = new SecureSwap(amm, token0, token1);

        victim = makeAddr("victim");
        frontRunner = makeAddr("frontRunner");
        token0.mint(victim, 1_000 ether);
        token0.mint(frontRunner, 5_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        QUIZ: THE FRONT-RUN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The attacker copies the plaintext answer and lands first.
     */
    function test_quiz_frontrun_succeeds_on_vulnerable() public {
        attackerVuln.attack(ANSWER);

        assertEq(attackerVuln.profit(), PRIZE, "attacker took the prize");
        assertTrue(vulnerableQuiz.solved());
        assertEq(vulnerableQuiz.winner(), address(attackerVuln));
        assertEq(address(vulnerableQuiz).balance, 0, "prize paid out");

        // The honest solver's transaction now reverts: the quiz is solved.
        vm.prank(victim);
        vm.expectRevert(VulnerableQuiz.AlreadySolved.selector);
        vulnerableQuiz.submitAnswer(ANSWER);
    }

    /**
     * @notice The front-runner can extract the prize it stole.
     */
    function test_quiz_attackerCanSweepPrize() public {
        attackerVuln.attack(ANSWER);

        uint256 before = address(this).balance;
        uint256 swept = attackerVuln.sweep();

        assertEq(swept, PRIZE);
        assertEq(address(this).balance, before + PRIZE);
        assertEq(attackerVuln.profit(), 0, "prize moved out");
    }

    /**
     * @notice A rejecting owner makes the sweep fail rather than lose funds.
     */
    function test_revertWhen_sweepToRejectingOwnerFails() public {
        RejectingSolver rejector = new RejectingSolver();
        Attacker stolen = rejector.deployAttacker(address(vulnerableQuiz));

        stolen.attack(ANSWER);
        assertEq(stolen.profit(), PRIZE);

        vm.expectRevert(Attacker.SweepFailed.selector);
        stolen.sweep();
    }

    /**
     * @notice The secure quiz has no plaintext entry point at all.
     */
    function test_quiz_frontrun_fails_on_secure() public {
        vm.expectRevert(SecureQuiz.PlaintextSubmissionDisabled.selector);
        attackerSec.attack(ANSWER);

        assertEq(attackerSec.profit(), 0);
        assertFalse(secureQuiz.solved());
        assertEq(address(secureQuiz).balance, PRIZE, "prize still held");
    }

    /**
     * @notice Commit-reveal rewards the honest solver after the delay.
     */
    function test_secure_quiz_commitRevealFlow() public {
        address solver = makeAddr("solver");
        bytes32 salt = keccak256("correct horse");
        bytes32 commitment = keccak256(abi.encode(ANSWER, salt, solver));

        vm.prank(solver);
        secureQuiz.commit(commitment);
        assertEq(secureQuiz.commitments(solver), commitment, "commitment stored");

        vm.prank(solver);
        vm.expectRevert(SecureQuiz.RevealTooEarly.selector);
        secureQuiz.reveal(ANSWER, salt);

        vm.roll(vm.getBlockNumber() + secureQuiz.REVEAL_DELAY());

        vm.prank(solver);
        secureQuiz.reveal(ANSWER, salt);

        assertTrue(secureQuiz.solved());
        assertEq(secureQuiz.winner(), solver);
        assertEq(solver.balance, PRIZE);
        assertEq(secureQuiz.commitments(solver), bytes32(0), "commitment cleared");
    }

    /**
     * @notice Copying the visible commitment does not let a front-runner claim
     *         it: the commitment is bound to the original committer.
     */
    function test_secure_quiz_rejectsCopiedCommitment() public {
        address solver = makeAddr("solver");
        address copycat = makeAddr("copycat");
        bytes32 salt = keccak256("correct horse");
        bytes32 commitment = keccak256(abi.encode(ANSWER, salt, solver));

        vm.prank(solver);
        secureQuiz.commit(commitment);
        vm.prank(copycat);
        secureQuiz.commit(commitment);

        vm.roll(vm.getBlockNumber() + secureQuiz.REVEAL_DELAY());

        vm.prank(copycat);
        vm.expectRevert(SecureQuiz.BadReveal.selector);
        secureQuiz.reveal(ANSWER, salt);

        vm.prank(solver);
        secureQuiz.reveal(ANSWER, salt);
        assertEq(secureQuiz.winner(), solver);
    }

    /*//////////////////////////////////////////////////////////////
                          SWAP: SLIPPAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A front-runner moves the pool and the unprotected swap settles at
     *         a far worse price.
     */
    function test_slippage_hits_vulnerable_swap() public {
        uint256 amountIn = 100 ether;
        uint256 fairOut = amm.quote(amountIn, true);

        // Attacker's transaction lands first and buys up the victim's output token.
        vm.prank(frontRunner);
        token0.approve(address(amm), 500 ether);
        vm.prank(frontRunner);
        amm.swap(500 ether, 0, 0, frontRunner);

        // Victim's unprotected swap settles at the manipulated price.
        vm.prank(victim);
        token0.approve(address(vulnerableSwap), amountIn);
        vm.prank(victim);
        uint256 received = vulnerableSwap.swapExactInput(amountIn);

        assertLt(received, fairOut, "victim got a worse price");
        assertLt(received, (fairOut * 80) / 100, "slippage exceeds 20%");
        assertEq(token1.balanceOf(victim), received);
    }

    /**
     * @notice With `minOut` set, the same front-run makes the trade revert
     *         instead of filling at the bad price.
     */
    function test_slippage_reverts_on_secure_swap() public {
        uint256 amountIn = 100 ether;
        uint256 fairOut = amm.quote(amountIn, true);
        uint256 minOut = (fairOut * 95) / 100;

        vm.prank(frontRunner);
        token0.approve(address(amm), 500 ether);
        vm.prank(frontRunner);
        amm.swap(500 ether, 0, 0, frontRunner);

        vm.prank(victim);
        token0.approve(address(secureSwap), amountIn);
        vm.prank(victim);
        vm.expectPartialRevert(MockAMM.InsufficientOutput.selector);
        secureSwap.swapExactInput(amountIn, minOut, vm.getBlockTimestamp() + 300);

        assertEq(token1.balanceOf(victim), 0, "no tokens traded");
    }

    /**
     * @notice A stale deadline is refused outright.
     */
    function test_secure_swap_revertsAfterDeadline() public {
        vm.prank(victim);
        token0.approve(address(secureSwap), 100 ether);

        vm.warp(vm.getBlockTimestamp() + 1_000);

        vm.prank(victim);
        vm.expectRevert(SecureSwap.DeadlineExpired.selector);
        secureSwap.swapExactInput(100 ether, 0, vm.getBlockTimestamp() - 1);
    }

    /**
     * @notice With an acceptable price the protected swap fills normally.
     */
    function test_secure_swap_succeedsWithinSlippage() public {
        uint256 amountIn = 100 ether;
        uint256 expected = amm.quote(amountIn, true);

        vm.prank(victim);
        token0.approve(address(secureSwap), amountIn);
        vm.prank(victim);
        uint256 received =
            secureSwap.swapExactInput(amountIn, expected, vm.getBlockTimestamp() + 300);

        assertEq(received, expected);
        assertEq(token1.balanceOf(victim), expected);
    }

    /*//////////////////////////////////////////////////////////////
                          INPUT / STATE GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_wrongPlaintextAnswer() public {
        vm.prank(victim);
        vm.expectRevert(VulnerableQuiz.WrongAnswer.selector);
        vulnerableQuiz.submitAnswer("nope");
    }

    function test_revertWhen_committingTwice() public {
        bytes32 commitment = keccak256("c");
        vm.prank(victim);
        secureQuiz.commit(commitment);
        vm.prank(victim);
        vm.expectRevert(SecureQuiz.CommitmentExists.selector);
        secureQuiz.commit(commitment);
    }

    function test_revertWhen_revealingWithoutCommitment() public {
        vm.prank(victim);
        vm.expectRevert(SecureQuiz.NoCommitment.selector);
        secureQuiz.reveal(ANSWER, keccak256("salt"));
    }

    function test_revertWhen_revealMismatch() public {
        address solver = makeAddr("solver");
        bytes32 salt = keccak256("salt");
        vm.prank(solver);
        secureQuiz.commit(keccak256(abi.encode(ANSWER, salt, solver)));

        vm.roll(vm.getBlockNumber() + secureQuiz.REVEAL_DELAY());

        vm.prank(solver);
        vm.expectRevert(SecureQuiz.BadReveal.selector);
        secureQuiz.reveal(ANSWER, keccak256("other salt"));
    }

    function test_revertWhen_revealingWrongAnswer() public {
        address solver = makeAddr("solver");
        bytes32 salt = keccak256("salt");
        vm.prank(solver);
        secureQuiz.commit(keccak256(abi.encode("wrong", salt, solver)));

        vm.roll(vm.getBlockNumber() + secureQuiz.REVEAL_DELAY());

        vm.prank(solver);
        vm.expectRevert(SecureQuiz.WrongAnswer.selector);
        secureQuiz.reveal("wrong", salt);
    }

    function test_revertWhen_solvedSecureQuizIsLocked() public {
        address solver = makeAddr("solver");
        bytes32 salt = keccak256("salt");
        vm.prank(solver);
        secureQuiz.commit(keccak256(abi.encode(ANSWER, salt, solver)));
        vm.roll(vm.getBlockNumber() + secureQuiz.REVEAL_DELAY());
        vm.prank(solver);
        secureQuiz.reveal(ANSWER, salt);

        vm.prank(victim);
        vm.expectRevert(SecureQuiz.AlreadySolved.selector);
        secureQuiz.commit(keccak256("x"));

        vm.prank(victim);
        vm.expectRevert(SecureQuiz.AlreadySolved.selector);
        secureQuiz.reveal(ANSWER, salt);
    }

    function test_revertWhen_payoutToRejectingContractFails() public {
        RejectingSolver rejector = new RejectingSolver();

        vm.expectRevert(VulnerableQuiz.PayoutFailed.selector);
        rejector.solve(vulnerableQuiz, ANSWER);

        bytes32 salt = keccak256("salt");
        rejector.commit(secureQuiz, keccak256(abi.encode(ANSWER, salt, address(rejector))));
        vm.roll(vm.getBlockNumber() + secureQuiz.REVEAL_DELAY());
        vm.expectRevert(SecureQuiz.PayoutFailed.selector);
        rejector.reveal(secureQuiz, ANSWER, salt);
    }

    function test_revertWhen_attackerRejectsZeroTarget() public {
        vm.expectRevert(Attacker.ZeroTarget.selector);
        new Attacker(address(0));
    }

    function test_revertWhen_vulnerableSwapRejectsZeroAmm() public {
        vm.expectRevert(VulnerableSwap.ZeroAddress.selector);
        new VulnerableSwap(MockAMM(address(0)), token0, token1);
    }

    function test_revertWhen_secureSwapRejectsZeroAmm() public {
        vm.expectRevert(SecureSwap.ZeroAddress.selector);
        new SecureSwap(MockAMM(address(0)), token0, token1);
    }

    function test_revertWhen_secureSwapRejectsZeroTokenOut() public {
        vm.expectRevert(SecureSwap.ZeroAddress.selector);
        new SecureSwap(amm, token0, MockERC20(address(0)));
    }
}
