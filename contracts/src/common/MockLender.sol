// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Callback interface a borrower must implement to receive a flash loan.
 * @dev The borrower is expected to do its work inside `onFlashLoan` and leave
 *      the principal in place by the time it returns.
 */
interface IFlashLoanReceiver {
    /**
     * @param initiator address that requested the loan (the borrower)
     * @param token     address of the borrowed ERC20
     * @param amount    principal lent
     * @param fee       fee that must be repaid (always 0 for {MockLender})
     * @param data      opaque payload supplied by the borrower
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}

/**
 * @title MockLender
 * @notice Fee-less flash-loan provider over a single ERC20, used by the
 *         flash-loan scenario (S5) where an attacker borrows governance tokens,
 *         votes, and repays inside one transaction.
 *
 * @dev The fee is deliberately zero so the scenario isolates the vulnerability
 *      itself (using a live balance) rather than profitable flash-loan
 *      arbitrage. The only invariant enforced is principal repayment.
 */
contract MockLender {
    /// @notice Flash loans are fee-free by design.
    uint256 public constant FEE = 0;

    /// @notice The only token this lender will lend.
    IERC20 public immutable lendingToken;

    /// @notice Per-provider deposit balance used for bookkeeping.
    mapping(address => uint256) public deposits;

    /// @notice Sum of all provider deposits.
    uint256 public totalDeposited;

    using SafeERC20 for IERC20;

    error InsufficientLiquidity(uint256 requested, uint256 available);
    error NotRepaid(uint256 required, uint256 actual);
    error InsufficientDeposit(uint256 requested, uint256 available);

    event Deposit(address indexed provider, uint256 amount);
    event Withdrawal(address indexed provider, uint256 amount);
    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);

    constructor(IERC20 lendingToken_) {
        lendingToken = lendingToken_;
    }

    /// @notice Largest loan this lender can currently serve.
    function maxFlashLoan() public view returns (uint256) {
        return lendingToken.balanceOf(address(this));
    }

    /// @notice Add `amount` tokens to the lendable pool and credit the provider.
    function deposit(uint256 amount) external {
        deposits[msg.sender] += amount;
        totalDeposited += amount;
        lendingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Withdraw previously deposited tokens.
    function withdraw(uint256 amount) external {
        uint256 available = deposits[msg.sender];
        if (amount > available) {
            revert InsufficientDeposit(amount, available);
        }
        deposits[msg.sender] = available - amount;
        totalDeposited -= amount;
        lendingToken.safeTransfer(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
    }

    /**
     * @notice Lend `amount` tokens for the duration of one external call.
     * @param amount principal to lend
     * @param data   opaque payload forwarded to the borrower's callback
     * @dev Reverts with {NotRepaid} unless the borrower restores the lender's
     *      token balance to at least its pre-loan value before returning.
     */
    function flashLoan(uint256 amount, bytes calldata data) external {
        uint256 balanceBefore = lendingToken.balanceOf(address(this));
        if (amount > balanceBefore) {
            revert InsufficientLiquidity(amount, balanceBefore);
        }

        lendingToken.safeTransfer(msg.sender, amount);
        emit FlashLoan(msg.sender, amount, FEE);

        IFlashLoanReceiver(msg.sender)
            .onFlashLoan(msg.sender, address(lendingToken), amount, FEE, data);

        uint256 balanceAfter = lendingToken.balanceOf(address(this));
        if (balanceAfter < balanceBefore) {
            revert NotRepaid(balanceBefore, balanceAfter);
        }
    }
}
