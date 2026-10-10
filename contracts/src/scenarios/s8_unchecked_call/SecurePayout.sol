// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockNonStandardERC20} from "../../common/MockNonStandardERC20.sol";
import {IPayout} from "./IPayout.sol";

/**
 * @title SecurePayout
 * @notice The S8 payout desk with every external transfer result enforced.
 * @dev FIX: the ETH transfer is checked and reverts with {TransferFailed} on
 *      failure, and the token side goes through OpenZeppelin {SafeERC20}, which
 *      reverts with `SafeERC20FailedOperation` when the non-standard token
 *      returns `false`. The ledger is only advanced once the value has
 *      demonstrably moved.
 */
contract SecurePayout is IPayout {
    using SafeERC20 for MockNonStandardERC20;

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
     * @dev FIX: state is written first (CEI), then the transfer result is
     *      checked and a failure reverts the whole call.
     */
    function payout(address payable to, uint256 amount) external override {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        totalEthPaid += amount;
        emit EthPaid(to, amount);
        // Paying a caller-named beneficiary is the desk's purpose; S8 isolates
        // the checked return value, not the destination policy.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool success,) = to.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    /// @inheritdoc IPayout
    function depositToken(uint256 amount) external override {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @inheritdoc IPayout
     * @dev FIX: SafeERC20 turns a `false` return into a revert.
     */
    function payoutToken(address to, uint256 amount) external override {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        totalTokenPaid += amount;
        emit TokenPaid(to, amount);
        token.safeTransfer(to, amount);
    }

    error TransferFailed();
    error ZeroAddress();
}
