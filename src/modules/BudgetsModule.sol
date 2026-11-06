// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ApprovalsModule} from "./ApprovalsModule.sol";
import {DateTime} from "../libs/DateTime.sol";
import {Budget} from "../OrgTypes.sol";

/// @notice Spend limits per budget id and calendar period. Every spend must name an existing budget.
abstract contract BudgetsModule is ApprovalsModule {
    /// @notice Id of the budget every business has from day one.
    bytes32 public constant GENERAL = keccak256("GENERAL");
    uint16 public constant MAX_BUDGET_PERIOD_MONTHS = 120;

    mapping(bytes32 => Budget) internal _budgets;

    event BudgetSet(bytes32 indexed budgetId, uint128 limit, uint16 periodMonths);

    error BudgetMissing(bytes32 budgetId);
    error BudgetExceeded(bytes32 budgetId, uint256 requested, uint256 remaining);
    error InvalidBudget();

    /// @notice Limit, amount spent in the current window, and the window bounds (end = max uint64 if never resets).
    function budgetStatus(bytes32 budgetId)
        external
        view
        returns (uint256 limit, uint256 spent, uint64 windowStart, uint64 windowEnd)
    {
        Budget storage b = _budgets[budgetId];
        if (!b.exists) revert BudgetMissing(budgetId);
        limit = b.limit;
        (windowStart, windowEnd) = _window(b);
        spent = windowStart > b.windowStart ? 0 : b.spent;
    }

    function _window(Budget storage b) internal view returns (uint64 start, uint64 end) {
        if (b.periodMonths == 0) return (b.anchor, type(uint64).max);
        uint256 periods = DateTime.diffMonths(b.anchor, block.timestamp) / b.periodMonths;
        uint256 months = periods * b.periodMonths;
        start = uint64(DateTime.addMonths(b.anchor, months));
        end = uint64(DateTime.addMonths(b.anchor, months + b.periodMonths));
    }

    /// @dev Adds `amount` to the budget's spend in the current window, rolling the window lazily.
    function _spendBudget(bytes32 budgetId, uint256 amount) internal {
        Budget storage b = _budgets[budgetId];
        if (!b.exists) revert BudgetMissing(budgetId);
        (uint64 start,) = _window(b);
        uint256 spent = b.spent;
        if (start > b.windowStart) {
            spent = 0;
            b.windowStart = start;
        }
        if (spent + amount > b.limit) revert BudgetExceeded(budgetId, amount, b.limit - spent);
        b.spent = uint128(spent + amount);
    }

    function _setBudget(bytes32 budgetId, uint128 limit, uint16 periodMonths) internal {
        if (budgetId == bytes32(0) || periodMonths > MAX_BUDGET_PERIOD_MONTHS) revert InvalidBudget();
        Budget storage b = _budgets[budgetId];
        if (!b.exists || b.periodMonths != periodMonths) {
            uint64 anchor = periodMonths == 0 ? uint64(block.timestamp) : uint64(DateTime.startOfMonth(block.timestamp));
            b.anchor = anchor;
            b.windowStart = anchor;
            b.spent = 0;
            b.periodMonths = periodMonths;
            b.exists = true;
        }
        b.limit = limit;
        emit BudgetSet(budgetId, limit, periodMonths);
    }
}
