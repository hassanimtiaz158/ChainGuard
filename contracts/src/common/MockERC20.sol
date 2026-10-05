// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mintable OpenZeppelin ERC20 used as the base token for the ChainGuard
 *         scenarios. Minting is deliberately permissionless: this is lab-only
 *         scaffolding that scenarios use to set up balances deterministically.
 * @dev Never deploy this outside the local lab chain (chain ID 31337).
 */
contract MockERC20 is ERC20 {
    uint8 private immutable _customDecimals;

    /**
     * @param name_     ERC20 name
     * @param symbol_   ERC20 symbol
     * @param decimals_ token decimals (18 is the usual choice)
     */
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    /// @notice Mint `amount` tokens to `to`. Permissionless on purpose.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burn `amount` tokens held by `from`. Permissionless on purpose.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
