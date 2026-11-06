// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {BudgetsModule} from "./BudgetsModule.sol";
import {Approval, SweepConfig} from "../OrgTypes.sol";

/// @notice Holds the vault's USDT accounting: liquid balance, the fixed yield pool, reserved vesting funds,
///         sweeping idle cash into the pool, recalling it, and funding by deposit.
abstract contract YieldModule is BudgetsModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdt;
    IAavePool public immutable aavePool;
    IERC20 public immutable aToken;
    /// @notice Sweeps smaller than this are rejected to stop gas spam.
    uint256 public immutable minSweepAmount;

    SweepConfig public sweepConfig;
    /// @notice USDT that is committed to unreleased vesting. Regular spending can never touch it.
    uint256 public reservedVesting;

    event Swept(uint256 amount, address indexed caller);
    event Recalled(uint256 amount);
    event Deposited(address indexed from, uint256 amount);
    event SweepConfigSet(bool enabled, uint128 minLiquid, uint128 maxInYield);

    error NothingToSweep();
    error InsufficientAvailable(uint256 requested, uint256 available);
    error ZeroAmount();

    constructor(address usdt_, address aavePool_, address aToken_, uint256 minSweepAmount_) {
        usdt = IERC20(usdt_);
        aavePool = IAavePool(aavePool_);
        aToken = IERC20(aToken_);
        minSweepAmount = minSweepAmount_;
    }

    // ---------------------------------------------------------------- views

    /// @notice USDT sitting in the vault.
    function liquidBalance() public view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    /// @notice USDT (principal plus accrued yield) supplied to the pool.
    function poolBalance() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Liquid USDT plus the pool balance.
    function totalAssets() public view returns (uint256) {
        return liquidBalance() + poolBalance();
    }

    /// @notice What regular payments may use: total assets minus reserved vesting.
    function availableToSpend() public view returns (uint256) {
        uint256 assets = totalAssets();
        return assets > reservedVesting ? assets - reservedVesting : 0;
    }

    // ------------------------------------------------------------ external

    /// @notice Move idle USDT above `minLiquid` into the fixed pool, up to `maxInYield`. Callable by anyone.
    function sweep() external nonReentrant {
        SweepConfig memory cfg = sweepConfig;
        if (!cfg.enabled) revert NothingToSweep();
        uint256 liquid = liquidBalance();
        if (liquid <= cfg.minLiquid) revert NothingToSweep();
        uint256 excess = liquid - cfg.minLiquid;
        uint256 inPool = poolBalance();
        uint256 room = cfg.maxInYield > inPool ? cfg.maxInYield - inPool : 0;
        uint256 amount = excess < room ? excess : room;
        if (amount == 0 || amount < minSweepAmount) revert NothingToSweep();
        usdt.forceApprove(address(aavePool), amount);
        aavePool.supply(address(usdt), amount, address(this), 0);
        emit Swept(amount, msg.sender);
    }

    /// @notice Pull `amount` back from the pool into the vault. Needs one approval.
    function recall(uint256 amount, uint256 nonce, uint64 validBefore, Approval[] calldata approvals)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        _authorize(
            keccak256(abi.encode(RECALL_TYPEHASH, amount, nonce, validBefore)),
            _clamp(1),
            validBefore,
            nonce,
            true,
            approvals
        );
        aavePool.withdraw(address(usdt), amount, address(this));
        emit Recalled(amount);
    }

    /// @notice Fund the vault with one EIP-3009 signature from `from`; anyone (the relayer) can submit it.
    function depositWithAuthorization(
        address from,
        uint256 value,
        uint64 validAfter,
        uint64 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        if (value == 0) revert ZeroAmount();
        IERC3009(address(usdt)).receiveWithAuthorization(from, address(this), value, validAfter, validBefore, nonce, v, r, s);
        emit Deposited(from, value);
    }

    // ------------------------------------------------------------ internals

    /// @dev Make sure `amount` USDT is liquid in the vault by withdrawing the shortfall from the pool.
    function _ensureLiquid(uint256 amount) internal {
        uint256 liquid = liquidBalance();
        if (liquid >= amount) return;
        aavePool.withdraw(address(usdt), amount - liquid, address(this));
    }

    function _setSweepConfig(SweepConfig memory cfg) internal {
        sweepConfig = cfg;
        emit SweepConfigSet(cfg.enabled, cfg.minLiquid, cfg.maxInYield);
    }

    /// @dev Pay `amount` USDT out of regular (non-reserved) funds.
    function _payFromAvailable(address to, uint256 amount) internal {
        uint256 available = availableToSpend();
        if (amount > available) revert InsufficientAvailable(amount, available);
        _ensureLiquid(amount);
        usdt.safeTransfer(to, amount);
    }
}
