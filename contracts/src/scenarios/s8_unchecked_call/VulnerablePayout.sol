// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockNonStandardERC20} from "../../common/MockNonStandardERC20.sol";
import {IPayout} from "./IPayout.sol";

/**
 * @title VulnerablePayout
 * @notice Payout desk that never checks whether its transfers actually happened
 *         (SWC-104, unchecked call return value).
 * @dev BUG: {payout} fires the low-level ETH call and {payoutToken} calls
 *      `transfer`, but neither result is inspected. A recipient that rejects
 *      ETH, or a token configured to return `false`, makes the transfer fail
 *      silently: `totalEthPaid` / `totalTokenPaid` advance while no value moves.
 *      The desk reports success to its caller and to off-chain accounting.
 */
contract VulnerablePayout is IPayout {
    /// @inheritdoc IPayout
    MockNonStandardERC20 public immutable token;

    /// @inheritdoc IPayout
    uint256 public totalEthPaid;

    /// @inheritdoc IPayout
    uint256 public totalTokenPaid;

    event Funded(address indexed from, uint256 amount);
    event EthPaid(address indexed to, uint256 amount);
    event TokenPaid(address indexed to, uint256 amount);

    /**
     * @param token_ non-standard ERC20 the desk pays out
     */
    constructor(MockNonStandardERC20 token_) {
        token = token_;
    }

    /// @inheritdoc IPayout
    function deposit() external payable override {
        emit Funded(msg.sender, msg.value);
    }

    /**
     * @inheritdoc IPayout
     * @dev BUG: the boolean returned by the low-level call is discarded.
     */
    function payout(address payable to, uint256 amount) external override {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        totalEthPaid += amount;
        emit EthPaid(to, amount);
        // The unchecked return is the vulnerability this scenario teaches.
        // forge-lint: disable-next-line(unchecked-call, arbitrary-send-eth)
        to.call{value: amount}("");
    }

    /// @inheritdoc IPayout
    function depositToken(uint256 amount) external override {
        // The deposit side ignores the return value too; approvals are set up by
        // the caller in the lab.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(msg.sender, address(this), amount);
    }

    /**
     * @inheritdoc IPayout
     * @dev BUG: `transfer` returns `false` on failure but the result is ignored,
     *      so the ledger records a payment the token never made.
     */
    function payoutToken(address to, uint256 amount) external override {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        totalTokenPaid += amount;
        emit TokenPaid(to, amount);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(to, amount);
    }

    error ZeroAddress();
}
