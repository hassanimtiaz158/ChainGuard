// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {stdError} from "forge-std/StdError.sol";

import {VulnerableToken} from "../../src/scenarios/s3_integer_logic/VulnerableToken.sol";
import {SecureToken} from "../../src/scenarios/s3_integer_logic/SecureToken.sol";
import {Attacker} from "../../src/scenarios/s3_integer_logic/Attacker.sol";

contract S3IntegerLogicTest is Test {
    VulnerableToken internal vulnerable;
    SecureToken internal secure;
    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    address internal constant USER = address(0xA11CE);
    address internal constant FUNDER = address(0xF00D);

    function setUp() public {
        vulnerable = new VulnerableToken();
        secure = new SecureToken();
        attackerVuln = new Attacker(address(vulnerable));
        attackerSec = new Attacker(address(secure));
    }

    /*//////////////////////////////////////////////////////////////
                       THE EXPLOIT (vulnerable)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice An over-transfer underflows instead of reverting, handing the
     *         attacker a near-maximal balance.
     */
    function test_unchecked_transfer_underflows_on_vulnerable() public {
        attackerVuln.attack();

        assertEq(vulnerable.balanceOf(address(attackerVuln)), type(uint256).max);
        assertEq(attackerVuln.profit(), type(uint256).max);
    }

    /**
     * @notice The underflow breaks the supply invariant: balances now sum to
     *         more than `totalSupply`.
     */
    function test_unchecked_transfer_breaks_the_supply_invariant() public {
        vulnerable.mint(USER, 10 ether);
        vulnerable.mint(FUNDER, 1 ether);

        uint256 supply = vulnerable.totalSupply();
        attackerVuln.attack();

        assertGt(
            vulnerable.balanceOf(address(attackerVuln)), supply, "a balance exceeds totalSupply"
        );
    }

    /**
     * @notice Divide-before-multiply truncates a member's share to zero even
     *         though the pool can afford to pay something.
     * @dev totalSupply = 10, rewardPool = 3, USER balance = 6.
     *      vulnerable: (3 / 10) * 6 = 0
     *      secure:     (3 * 6) / 10 = 1
     */
    function test_divide_before_multiply_truncates() public {
        _seedRewardPool();

        assertEq(vulnerable.pendingReward(USER), 0, "truncated to zero");
        assertEq(secure.pendingReward(USER), 1, "full precision");
    }

    /*//////////////////////////////////////////////////////////////
                        THE DEFENSE (secure)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The same attack reverts with a checked-arithmetic panic.
     */
    function test_transfer_reverts_on_secure() public {
        vm.expectRevert(stdError.arithmeticError);
        attackerSec.attack();

        assertEq(secure.balanceOf(address(attackerSec)), 0, "balance untouched");
        assertEq(attackerSec.profit(), 0);
    }

    /**
     * @notice The secure reward formula pays the member correctly.
     */
    function test_claim_pays_the_correct_share() public {
        _seedRewardPool();

        vm.prank(USER);
        uint256 reward = secure.claim();
        assertEq(reward, 1);
        assertEq(secure.balanceOf(USER), 6 + 1);
        assertEq(secure.rewardPool(), 3 - 1);

        // The vulnerable token computes a zero share, so it silently pays
        // nothing.
        vm.prank(USER);
        uint256 vulnerableReward = vulnerable.claim();
        assertEq(vulnerableReward, 0, "rounding pays nothing");
        assertEq(vulnerable.balanceOf(USER), 6);
        assertEq(vulnerable.rewardPool(), 3);
    }

    /*//////////////////////////////////////////////////////////////
                          NORMAL BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Honest transfers move tokens on both tokens.
     */
    function testFuzz_transfer_moves_funds(uint256 amount) public {
        amount = bound(amount, 1, 1000 ether);

        vulnerable.mint(address(this), amount);
        secure.mint(address(this), amount);

        vulnerable.transfer(USER, amount);
        secure.transfer(USER, amount);

        assertEq(vulnerable.balanceOf(USER), amount);
        assertEq(secure.balanceOf(USER), amount);
        assertEq(vulnerable.balanceOf(address(this)), 0);
        assertEq(secure.balanceOf(address(this)), 0);
    }

    /**
     * @notice With no supply, a reward is simply zero.
     */
    function test_pendingReward_is_zero_with_no_supply() public view {
        assertEq(vulnerable.pendingReward(USER), 0);
        assertEq(secure.pendingReward(USER), 0);
    }

    /**
     * @notice Both tokens still enforce the basic input guards.
     */
    function test_revertWhen_inputsAreInvalid() public {
        vm.expectRevert(VulnerableToken.ZeroAddress.selector);
        vulnerable.mint(address(0), 1);

        vm.expectRevert(VulnerableToken.ZeroAmount.selector);
        vulnerable.mint(USER, 0);

        vm.expectRevert(VulnerableToken.ZeroAddress.selector);
        vulnerable.transfer(address(0), 1);

        vm.expectRevert(VulnerableToken.ZeroAmount.selector);
        vulnerable.fundRewards(0);

        vm.expectRevert(SecureToken.ZeroAddress.selector);
        secure.mint(address(0), 1);

        vm.expectRevert(SecureToken.ZeroAmount.selector);
        secure.mint(USER, 0);

        vm.expectRevert(SecureToken.ZeroAddress.selector);
        secure.transfer(address(0), 1);

        vm.expectRevert(SecureToken.ZeroAmount.selector);
        secure.fundRewards(0);
    }

    /// @dev totalSupply = 10, rewardPool = 3, USER balance = 6 on both tokens.
    function _seedRewardPool() internal {
        vulnerable.mint(USER, 6);
        secure.mint(USER, 6);
        vulnerable.mint(FUNDER, 4);
        secure.mint(FUNDER, 4);

        vm.prank(FUNDER);
        vulnerable.fundRewards(3);
        vm.prank(FUNDER);
        secure.fundRewards(3);
    }
}

/**
 * @dev Drives mint/transfer on the secure token with bounded inputs so the
 *      supply invariant can be exercised over many sequences.
 */
contract SecureTokenHandler is Test {
    SecureToken internal immutable token;
    address[] internal actors;

    constructor(SecureToken token_) {
        token = token_;
        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        amount = bound(amount, 1, 1000e18);
        token.mint(actor, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[bound(fromSeed, 0, actors.length - 1)];
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) {
            return;
        }
        amount = bound(amount, 1, balance);
        vm.prank(from);
        token.transfer(to, amount);
    }
}

contract S3IntegerLogicInvariantTest is StdInvariant, Test {
    SecureToken internal token;
    SecureTokenHandler internal handler;

    function setUp() public {
        token = new SecureToken();
        handler = new SecureTokenHandler(token);
        targetContract(address(handler));
    }

    /**
     * @notice The sum of every tracked balance must never exceed the supply.
     *         Checked arithmetic keeps this true for the secure token; the
     *         vulnerable token breaks it (see
     *         `test_unchecked_transfer_breaks_the_supply_invariant`).
     */
    function invariant_totalBalancesNeverExceedSupply() public view {
        uint256 sum = token.balanceOf(address(token));
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertLe(sum, token.totalSupply(), "balances must never exceed supply");
    }
}
