// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {PaymentsModule} from "./PaymentsModule.sol";
import {DateTime} from "../libs/DateTime.sol";
import {Approval, Schedule, ScheduleCreateData, Unit} from "../OrgTypes.sol";

/// @notice Recurring vendor schedules. A schedule is approved once; every run needs fresh approvals when due.
abstract contract SchedulesModule is PaymentsModule {
    mapping(uint256 => Schedule) internal _schedules;
    mapping(uint256 => mapping(uint256 => bool)) public paidRun;
    mapping(uint256 => uint256) internal _lowestUnpaid;
    uint256 public scheduleCount;

    event ScheduleCreated(
        uint256 indexed id, address indexed payee, uint256 amount, uint64 start, uint64 end, Unit unit, uint16 every, bytes32 budgetId, bytes32 ref
    );
    event ScheduleCancelled(uint256 indexed id);
    event ScheduledRunPaid(uint256 indexed id, uint256 indexed run, address indexed payee, uint256 amount);

    error ScheduleInactive(uint256 id);
    error ScheduleNotFound(uint256 id);
    error ScheduleEnded(uint256 id, uint256 run);
    error RunNotDue(uint256 id, uint256 run, uint64 dueAt);
    error RunAlreadyPaid(uint256 id, uint256 run);
    error InvalidSchedule();

    function getSchedule(uint256 id) external view returns (Schedule memory) {
        if (id >= scheduleCount) revert ScheduleNotFound(id);
        return _schedules[id];
    }

    /// @notice When run `run` falls due: start + run * every (days, weeks, or calendar months).
    function runDueTime(uint256 id, uint256 run) public view returns (uint64) {
        Schedule storage s = _schedules[id];
        if (id >= scheduleCount) revert ScheduleNotFound(id);
        uint256 steps = run * s.every;
        if (s.unit == Unit.MONTH) return uint64(DateTime.addMonths(s.start, steps));
        return uint64(s.start + steps * (s.unit == Unit.DAY ? 1 days : 7 days));
    }

    /// @notice Lowest run not yet paid and when it is due. dueAt is 0 if the schedule is cancelled or has ended.
    function nextUnpaidRun(uint256 id) external view returns (uint256 run, uint64 dueAt) {
        if (id >= scheduleCount) revert ScheduleNotFound(id);
        run = _lowestUnpaid[id];
        Schedule storage s = _schedules[id];
        if (!s.active) return (run, 0);
        dueAt = runDueTime(id, run);
        if (s.end != 0 && dueAt > s.end) dueAt = 0;
    }

    function createSchedule(ScheduleCreateData calldata s, Approval[] calldata approvals)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (!isPayee[s.payee]) revert PayeeNotRegistered(s.payee);
        if (s.amount == 0 || s.amount > type(uint128).max || s.every == 0 || s.start == 0) revert InvalidSchedule();
        if (s.end != 0 && s.end < s.start) revert InvalidSchedule();
        if (!_budgets[s.budgetId].exists) revert BudgetMissing(s.budgetId);
        _authorize(
            keccak256(abi.encode(SCHEDULE_CREATE_TYPEHASH, s)),
            approvalsRequired(s.amount),
            s.validBefore,
            s.nonce,
            true,
            approvals
        );
        id = scheduleCount++;
        _schedules[id] = Schedule({
            payee: s.payee,
            amount: uint128(s.amount),
            start: s.start,
            end: s.end,
            unit: s.unit,
            every: s.every,
            budgetId: s.budgetId,
            ref: s.ref,
            active: true
        });
        emit ScheduleCreated(id, s.payee, s.amount, s.start, s.end, s.unit, s.every, s.budgetId, s.ref);
    }

    /// @notice Pay one due run. Needs fresh approvals for the tier of the per-run amount.
    function executeScheduledRun(uint256 id, uint256 run, uint64 validBefore, Approval[] calldata approvals)
        external
        nonReentrant
    {
        if (id >= scheduleCount) revert ScheduleNotFound(id);
        Schedule memory s = _schedules[id];
        if (!s.active) revert ScheduleInactive(id);
        if (paidRun[id][run]) revert RunAlreadyPaid(id, run);
        uint64 dueAt = runDueTime(id, run);
        if (s.end != 0 && dueAt > s.end) revert ScheduleEnded(id, run);
        if (block.timestamp < dueAt) revert RunNotDue(id, run, dueAt);
        if (!isPayee[s.payee]) revert PayeeNotRegistered(s.payee);

        _authorize(
            keccak256(abi.encode(SCHEDULED_RUN_TYPEHASH, id, run, validBefore)),
            approvalsRequired(s.amount),
            validBefore,
            0,
            false,
            approvals
        );
        paidRun[id][run] = true;
        uint256 next = _lowestUnpaid[id];
        while (paidRun[id][next]) ++next;
        _lowestUnpaid[id] = next;

        _spendBudget(s.budgetId, s.amount);
        _payFromAvailable(s.payee, s.amount);
        emit ScheduledRunPaid(id, run, s.payee, s.amount);
    }

    /// @notice Cancel a schedule. One approval.
    function cancelSchedule(uint256 id, uint256 nonce, uint64 validBefore, Approval[] calldata approvals) external {
        if (id >= scheduleCount) revert ScheduleNotFound(id);
        if (!_schedules[id].active) revert ScheduleInactive(id);
        _authorize(
            keccak256(abi.encode(SCHEDULE_CANCEL_TYPEHASH, id, nonce, validBefore)),
            _clamp(1),
            validBefore,
            nonce,
            true,
            approvals
        );
        _schedules[id].active = false;
        emit ScheduleCancelled(id);
    }
}
