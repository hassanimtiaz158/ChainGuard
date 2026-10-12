// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {Attacker} from "../../src/scenarios/s7_sig_replay/Attacker.sol";
import {SecureClaim} from "../../src/scenarios/s7_sig_replay/SecureClaim.sol";
import {VulnerableClaim} from "../../src/scenarios/s7_sig_replay/VulnerableClaim.sol";

/// @dev A contract with no receive/fallback, so ETH payouts to it revert.
contract RejectingRecipient {
    function deployAttacker(address target) external returns (Attacker) {
        return new Attacker(target);
    }
}

/**
 * @notice Scenario S7: signature replay.
 * @dev A voucher signed over `(to, amount)` only can be redeemed repeatedly
 *      against {VulnerableClaim}. {SecureClaim} adds an EIP-712 domain
 *      (chain id + verifying contract) and a per-recipient nonce, so the second
 *      submission of the exact same signature reverts.
 */
contract S7SignatureReplayTest is Test {
    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant FUNDING = 5 ether;

    address internal signer;
    VulnerableClaim internal vulnerableClaim;
    SecureClaim internal secureClaim;
    Attacker internal attackerVuln;
    Attacker internal attackerSec;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 100 ether);
        signer = vm.addr(SIGNER_PK);

        vulnerableClaim = new VulnerableClaim(signer);
        secureClaim = new SecureClaim(signer);
        _fund(address(vulnerableClaim));
        _fund(address(secureClaim));

        attackerVuln = new Attacker(address(vulnerableClaim));
        attackerSec = new Attacker(address(secureClaim));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fund(address target) internal {
        (bool ok,) = payable(target).call{value: FUNDING}("");
        assertTrue(ok, "fund failed");
    }

    /// @dev Sign the vulnerable `(to, amount)` eth-message digest.
    function _signVoucher(address to, uint256 amount) internal pure returns (bytes memory) {
        bytes32 digest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encodePacked(to, amount)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign the secure EIP-712 `Claim(to, amount, nonce)` digest.
    function _signTypedClaim(address to, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_PK, secureClaim.hashClaim(to, amount, nonce));
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                          THE REPLAY ATTACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The same signature can be redeemed over and over.
     */
    function test_replay_succeeds_on_vulnerable() public {
        bytes memory signature = _signVoucher(address(attackerVuln), AMOUNT);

        attackerVuln.attack(AMOUNT, 0, signature);
        assertEq(attackerVuln.profit(), AMOUNT, "first redemption paid");

        // Identical signature, identical vouchers.
        attackerVuln.attack(AMOUNT, 0, signature);
        assertEq(attackerVuln.profit(), 2 * AMOUNT, "same voucher replayed");

        attackerVuln.attack(AMOUNT, 0, signature);
        assertEq(attackerVuln.profit(), 3 * AMOUNT);
        assertEq(vulnerableClaim.totalClaimed(), 3 * AMOUNT);
        assertEq(address(vulnerableClaim).balance, FUNDING - 3 * AMOUNT);
    }

    /**
     * @notice The same replay is rejected once the nonce is bound.
     */
    function test_replay_fails_on_secure() public {
        uint256 nonce = secureClaim.nonces(address(attackerSec));
        bytes memory signature = _signTypedClaim(address(attackerSec), AMOUNT, nonce);

        attackerSec.attack(AMOUNT, nonce, signature);
        assertEq(attackerSec.profit(), AMOUNT, "paid once");
        assertEq(secureClaim.nonces(address(attackerSec)), nonce + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Nonces.InvalidAccountNonce.selector, address(attackerSec), nonce + 1
            )
        );
        attackerSec.attack(AMOUNT, nonce, signature);

        assertEq(attackerSec.profit(), AMOUNT, "no second payout");
        assertEq(address(secureClaim).balance, FUNDING - AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                          DOMAIN SEPARATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A signature for one deployment is invalid on another because the
     *         EIP-712 domain separator includes the verifying contract.
     */
    function test_secure_signatureIsBoundToContract() public {
        SecureClaim other = new SecureClaim(signer);
        _fund(address(other));

        bytes memory signature = _signTypedClaim(address(attackerSec), AMOUNT, 0);

        vm.expectRevert(SecureClaim.BadSignature.selector);
        other.claim(payable(address(attackerSec)), AMOUNT, 0, signature);
    }

    /**
     * @notice Nonces are tracked per recipient, so one claimant cannot consume
     *         another claimant's sequence.
     */
    function test_secure_noncesArePerRecipient() public {
        address bob = makeAddr("bob");

        uint256 nonce = secureClaim.nonces(address(attackerSec));
        attackerSec.attack(AMOUNT, nonce, _signTypedClaim(address(attackerSec), AMOUNT, nonce));

        // Bob's sequence is untouched.
        assertEq(secureClaim.nonces(bob), 0);
        secureClaim.claim(payable(bob), AMOUNT, 0, _signTypedClaim(bob, AMOUNT, 0));
        assertEq(bob.balance, AMOUNT);
        assertEq(secureClaim.nonces(bob), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          INPUT / STATE GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_badSignatureOnVulnerable() public {
        bytes memory signature = _signVoucher(address(attackerVuln), AMOUNT);
        vm.expectRevert(VulnerableClaim.BadSignature.selector);
        vulnerableClaim.claim(payable(makeAddr("someoneElse")), AMOUNT, 0, signature);
    }

    function test_revertWhen_badSignatureOnSecure() public {
        bytes memory signature = _signTypedClaim(address(attackerSec), AMOUNT, 0);
        vm.expectRevert(SecureClaim.BadSignature.selector);
        secureClaim.claim(payable(makeAddr("someoneElse")), AMOUNT, 0, signature);
    }

    function test_revertWhen_secureClaimingToZeroRecipient() public {
        vm.expectRevert(SecureClaim.ZeroRecipient.selector);
        secureClaim.claim(payable(address(0)), AMOUNT, 0, _signVoucher(address(0), AMOUNT));
    }

    function test_revertWhen_vulnerableClaimingToZeroRecipient() public {
        vm.expectRevert(VulnerableClaim.ZeroRecipient.selector);
        vulnerableClaim.claim(payable(address(0)), AMOUNT, 0, _signVoucher(address(0), AMOUNT));
    }

    function test_revertWhen_vulnerableRejectsZeroSigner() public {
        vm.expectRevert(VulnerableClaim.ZeroSigner.selector);
        new VulnerableClaim(address(0));
    }

    function test_revertWhen_secureRejectsZeroSigner() public {
        vm.expectRevert(SecureClaim.ZeroSigner.selector);
        new SecureClaim(address(0));
    }

    function test_revertWhen_vulnerablePayoutToRejectingRecipientFails() public {
        RejectingRecipient rejector = new RejectingRecipient();
        vm.expectRevert(VulnerableClaim.PayoutFailed.selector);
        vulnerableClaim.claim(
            payable(address(rejector)), AMOUNT, 0, _signVoucher(address(rejector), AMOUNT)
        );
    }

    function test_revertWhen_securePayoutToRejectingRecipientFails() public {
        RejectingRecipient rejector = new RejectingRecipient();
        uint256 nonce = secureClaim.nonces(address(rejector));
        bytes memory signature = _signTypedClaim(address(rejector), AMOUNT, nonce);

        vm.expectRevert(SecureClaim.PayoutFailed.selector);
        secureClaim.claim(payable(address(rejector)), AMOUNT, nonce, signature);
    }

    function test_revertWhen_attackerRejectsZeroTarget() public {
        vm.expectRevert(Attacker.ZeroTarget.selector);
        new Attacker(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              ATTACKER
    //////////////////////////////////////////////////////////////*/

    function test_attackerCanSweepReplayedFunds() public {
        attackerVuln.attack(AMOUNT, 0, _signVoucher(address(attackerVuln), AMOUNT));

        uint256 before = address(this).balance;
        uint256 swept = attackerVuln.sweep();

        assertEq(swept, AMOUNT);
        assertEq(address(this).balance, before + AMOUNT);
        assertEq(attackerVuln.profit(), 0, "funds moved out");
    }

    function test_revertWhen_sweepToRejectingOwnerFails() public {
        RejectingRecipient rejector = new RejectingRecipient();
        Attacker stolen = rejector.deployAttacker(address(vulnerableClaim));
        stolen.attack(AMOUNT, 0, _signVoucher(address(stolen), AMOUNT));

        vm.expectRevert(Attacker.SweepFailed.selector);
        stolen.sweep();
    }

    function test_signersAreExposed() public view {
        assertEq(vulnerableClaim.signer(), signer);
        assertEq(secureClaim.signer(), signer);
    }
}
