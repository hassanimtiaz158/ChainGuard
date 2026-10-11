// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IClaim} from "./IClaim.sol";

/**
 * @title VulnerableClaim
 * @notice Voucher vault that pays out against an ECDSA signature.
 * @dev BUG: the signed payload is only `(to, amount)`. A `nonce` is accepted
 *      and emitted but it is neither part of the signed digest nor recorded
 *      on-chain, and the digest is not bound to this contract or to the chain
 *      id. A captured signature therefore stays valid forever: the same voucher
 *      can be redeemed over and over. {SecureClaim} shows the EIP-712 + nonce
 *      fix.
 */
contract VulnerableClaim is IClaim {
    /// @inheritdoc IClaim
    address public immutable signer;

    /// @notice Running total paid out, for bookkeeping and assertions.
    uint256 public totalClaimed;

    error ZeroSigner();
    error ZeroRecipient();
    error BadSignature();
    error PayoutFailed();

    event Claimed(address indexed to, uint256 amount, uint256 nonce);

    /**
     * @param signer_ address whose signature authorises payouts
     */
    constructor(address signer_) {
        if (signer_ == address(0)) {
            revert ZeroSigner();
        }
        signer = signer_;
    }

    receive() external payable {}

    /// @inheritdoc IClaim
    function claim(address payable to, uint256 amount, uint256 nonce, bytes calldata signature)
        external
    {
        if (to == address(0)) {
            revert ZeroRecipient();
        }
        if (!_verifyVoucher(to, amount, signature)) {
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
     * @dev BUG: the digest commits only to `(to, amount)`. The `nonce` handed
     *      to {claim} is never mixed in, so every signature is replayable.
     */
    function _verifyVoucher(address to, uint256 amount, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        bytes32 digest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encodePacked(to, amount)));
        return ECDSA.recover(digest, signature) == signer;
    }
}
