// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {IClaim} from "./IClaim.sol";

/**
 * @title SecureClaim
 * @notice The S7 voucher vault with replay protection.
 * @dev FIX: vouchers are EIP-712 typed data. The signed struct is
 *      `Claim(address to, uint256 amount, uint256 nonce)`, and the EIP-712
 *      domain separator already commits to the chain id and to this contract's
 *      address, so a signature cannot be reused on another deployment or
 *      another chain. Each recipient has a nonce sequence from OpenZeppelin
 *      {Nonces}; `claim` consumes the expected nonce, so the same voucher can
 *      only ever be redeemed once.
 */
contract SecureClaim is IClaim, EIP712, Nonces {
    /// @inheritdoc IClaim
    address public immutable signer;

    /// @notice Running total paid out, for bookkeeping and assertions.
    uint256 public totalClaimed;

    /// @dev keccak256("Claim(address to,uint256 amount,uint256 nonce)")
    bytes32 private constant CLAIM_TYPEHASH =
        keccak256("Claim(address to,uint256 amount,uint256 nonce)");

    error ZeroSigner();
    error ZeroRecipient();
    error BadSignature();
    error PayoutFailed();

    event Claimed(address indexed to, uint256 amount, uint256 nonce);

    /**
     * @param signer_ address whose signature authorises payouts
     */
    constructor(address signer_) EIP712("ChainGuardClaim", "1") {
        if (signer_ == address(0)) {
            revert ZeroSigner();
        }
        signer = signer_;
    }

    receive() external payable {}

    /**
     * @notice EIP-712 digest a signer must sign to authorise a payout.
     */
    function hashClaim(address to, uint256 amount, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, to, amount, nonce)));
    }

    /// @inheritdoc IClaim
    function claim(address payable to, uint256 amount, uint256 nonce, bytes calldata signature)
        external
    {
        if (to == address(0)) {
            revert ZeroRecipient();
        }

        // FIX: each recipient's vouchers carry a strictly sequential nonce, and
        // using it here makes the voucher single-use.
        _useCheckedNonce(to, nonce);

        if (!_verifyVoucher(to, amount, nonce, signature)) {
            revert BadSignature();
        }

        totalClaimed += amount;
        // `ECDSA.recover` / `MessageHashUtils` are pure helpers, but forge-lint
        // scores the cross-file library calls as external interactions. No
        // untrusted code runs before this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(to, amount, nonce);

        // The recipient is authorised by the signer's voucher.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            revert PayoutFailed();
        }
    }

    /**
     * @dev FIX: the digest is EIP-712 typed data over `(to, amount, nonce)`,
     *      bound to this domain separator.
     */
    function _verifyVoucher(address to, uint256 amount, uint256 nonce, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        return ECDSA.recover(hashClaim(to, amount, nonce), signature) == signer;
    }
}
