// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title GovernanceToken
 * @notice ERC20 with vote checkpoints, used by scenario S5.
 * @dev The point of the scenario is that this token *does* keep a history of
 *      voting power ({Votes-getPastVotes}). The vulnerable governance ignores
 *      that history and reads live balances; the secure one reads the
 *      checkpoint fixed at the proposal snapshot. Minting is permissionless for
 *      the lab only.
 */
contract GovernanceToken is ERC20Votes {
    constructor() ERC20("ChainGuard Governance", "CGG") EIP712("ChainGuard Governance", "1") {}

    /// @notice Mint `amount` tokens to `to`. Permissionless on purpose.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
