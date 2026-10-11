// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Shared interface for the mock voucher vaults in scenario S7
 *         (signature replay).
 * @dev `VulnerableClaim` and `SecureClaim` pay out on an issuer signature, but
 *      only the secure one binds the voucher to a nonce, this contract and this
 *      chain.
 */
interface IClaim {
    /**
     * @notice Redeem a signed voucher.
     * @param to        recipient of the payout
     * @param amount    amount to pay
     * @param nonce     single-use identifier bound by the secure variant
     * @param signature issuer signature over the voucher
     */
    function claim(address payable to, uint256 amount, uint256 nonce, bytes calldata signature)
        external;

    /// @notice Address whose signature authorises payouts.
    function signer() external view returns (address);
}
