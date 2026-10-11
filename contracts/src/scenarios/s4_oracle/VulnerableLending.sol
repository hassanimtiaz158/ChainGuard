// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockAMM} from "../../common/MockAMM.sol";
import {MockERC20} from "../../common/MockERC20.sol";
import {ILending} from "./ILending.sol";

/**
 * @title VulnerableLending
 * @notice Collateralised lending pool that values collateral using the AMM's
 *         *instantaneous* spot price.
 * @dev BUG: {price} returns {MockAMM-getSpotPrice} verbatim. A single swap can
 *      move that number arbitrarily within one block, so the attacker inflates
 *      the value of their collateral, borrows far past the honest loan-to-value
 *      limit, and leaves the pool holding bad debt. The hardened contract
 *      ({SecureLending}) consults a TWAP and rejects readings that deviate too
 *      far from it.
 */
contract VulnerableLending is ILending {
    using SafeERC20 for MockERC20;

    /// @notice Basis-point denominator (100% = 10_000).
    uint256 public constant BPS = 10_000;

    /// @notice Loan-to-value ratio: how much may be borrowed per unit of
    ///         collateral value.
    uint256 public constant LTV_BPS = 5_000;

    /// @notice Fixed-point scale of the oracle price.
    uint256 public constant PRICE_SCALE = 1e18;

    MockAMM private immutable _amm;

    /// @notice Token accepted as collateral (the AMM's token0).
    MockERC20 public immutable collateralToken;

    /// @notice Token lent out (the AMM's token1).
    MockERC20 public immutable borrowToken;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    error ZeroAmount();
    error InsufficientCollateral(uint256 requested, uint256 available);
    error OverLtv(uint256 debt, uint256 maxDebt);

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);

    /**
     * @param amm_ AMM whose spot price is used as the collateral oracle.
     */
    constructor(MockAMM amm_) {
        _amm = amm_;
        collateralToken = amm_.token0();
        borrowToken = amm_.token1();
    }

    /// @inheritdoc ILending
    function amm() external view returns (address) {
        return address(_amm);
    }

    /// @inheritdoc ILending
    /// @dev BUG: the manipulable single-block spot price is trusted directly.
    function price() public view returns (uint256) {
        return _amm.getSpotPrice();
    }

    /// @inheritdoc ILending
    function collateralValueOf(address user) public view returns (uint256) {
        return (collateralOf[user] * price()) / PRICE_SCALE;
    }

    /// @inheritdoc ILending
    function maxBorrow(address user) public view returns (uint256) {
        return (collateralValueOf(user) * LTV_BPS) / BPS;
    }

    /// @inheritdoc ILending
    function depositCollateral(uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }
        collateralOf[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc ILending
    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 available = collateralOf[msg.sender];
        if (amount > available) {
            revert InsufficientCollateral(amount, available);
        }

        collateralOf[msg.sender] = available - amount;
        uint256 maxDebt = maxBorrow(msg.sender);
        if (debtOf[msg.sender] > maxDebt) {
            revert OverLtv(debtOf[msg.sender], maxDebt);
        }

        emit CollateralWithdrawn(msg.sender, amount);
        collateralToken.safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc ILending
    function borrow(uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }
        debtOf[msg.sender] += amount;
        uint256 maxDebt = maxBorrow(msg.sender);
        if (debtOf[msg.sender] > maxDebt) {
            revert OverLtv(debtOf[msg.sender], maxDebt);
        }

        emit Borrowed(msg.sender, amount);
        borrowToken.safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc ILending
    function repay(uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 debt = debtOf[msg.sender];
        uint256 payment = amount > debt ? debt : amount;
        debtOf[msg.sender] = debt - payment;

        emit Repaid(msg.sender, payment);
        borrowToken.safeTransferFrom(msg.sender, address(this), payment);
    }
}
