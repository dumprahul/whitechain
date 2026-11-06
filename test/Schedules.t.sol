// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/Base.t.sol";
import {DateTime} from "../src/libs/DateTime.sol";
import {ApprovalsModule} from "../src/modules/ApprovalsModule.sol";
import {BudgetsModule} from "../src/modules/BudgetsModule.sol";
import {PaymentsModule} from "../src/modules/PaymentsModule.sol";
import {SchedulesModule} from "../src/modules/SchedulesModule.sol";
import {Approval, Schedule, ScheduleCreateData, Unit} from "../src/OrgTypes.sol";

contract SchedulesTest is BaseTest {
    uint64 internal start;

    function setUp() public override {
        super.setUp();
        start = uint64(block.timestamp);
    }

    function test_createSchedule() public {
        uint256 id = _createSchedule(vendor, 500 * U, Unit.MONTH, 1, start, 0);
        assertEq(id, 0);
        assertEq(vault.scheduleCount(), 1);
        Schedule memory s = vault.getSchedule(0);
        assertEq(s.payee, vendor);
        assertEq(s.amount, 500 * U);
        assertTrue(s.active);
    }

    function test_createSchedule_needsTierApprovals() public {
        ScheduleCreateData memory s = _newSchedule(vendor, 1_500 * U, Unit.MONTH, 1, start, 0);
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, 1, 3));
        vault.createSchedule(s, _approvalsFor(vault, _hSchedule(s), 1));
        vault.createSchedule(s, _approvalsFor(vault, _hSchedule(s), 3));
    }

    function test_createSchedule_invalid() public {
        Approval[] memory none = new Approval[](0);
        ScheduleCreateData memory s = _newSchedule(stranger, 1 * U, Unit.DAY, 1, start, 0);
        vm.expectRevert(abi.encodeWithSelector(PaymentsModule.PayeeNotRegistered.selector, stranger));
        vault.createSchedule(s, none);

        s = _newSchedule(vendor, 0, Unit.DAY, 1, start, 0);
        vm.expectRevert(SchedulesModule.InvalidSchedule.selector);
        vault.createSchedule(s, none);

        s = _newSchedule(vendor, 1, Unit.DAY, 0, start, 0); // every = 0
        vm.expectRevert(SchedulesModule.InvalidSchedule.selector);
        vault.createSchedule(s, none);

        s = _newSchedule(vendor, 1, Unit.DAY, 1, 0, 0); // start = 0
        vm.expectRevert(SchedulesModule.InvalidSchedule.selector);
        vault.createSchedule(s, none);

        s = _newSchedule(vendor, 1, Unit.DAY, 1, start, start - 1); // end before start
        vm.expectRevert(SchedulesModule.InvalidSchedule.selector);
        vault.createSchedule(s, none);

        s = _newSchedule(vendor, 1, Unit.DAY, 1, start, 0);
        s.budgetId = keccak256("NOPE");
        vm.expectRevert(abi.encodeWithSelector(BudgetsModule.BudgetMissing.selector, s.budgetId));
        vault.createSchedule(s, none);
    }

    function test_runDueTime() public {
        uint256 d = _createSchedule(vendor, 10 * U, Unit.DAY, 3, start, 0);
        uint256 w = _createSchedule(vendor, 10 * U, Unit.WEEK, 2, start, 0);
        uint256 m = _createSchedule(vendor, 10 * U, Unit.MONTH, 1, start, 0);
        assertEq(vault.runDueTime(d, 0), start);
        assertEq(vault.runDueTime(d, 2), start + 6 days);
        assertEq(vault.runDueTime(w, 1), start + 14 days);
        assertEq(vault.runDueTime(m, 1), DateTime.addMonths(start, 1));
        assertEq(vault.runDueTime(m, 12), DateTime.addMonths(start, 12));
    }

    function test_runDueTime_monthEndClamps() public {
        uint64 jan31 = uint64(DateTime.timestampFromDate(2025, 1, 31));
        uint256 id = _createSchedule(vendor, 10 * U, Unit.MONTH, 1, jan31, 0);
        assertEq(vault.runDueTime(id, 1), DateTime.timestampFromDate(2025, 2, 28));
        assertEq(vault.runDueTime(id, 2), DateTime.timestampFromDate(2025, 3, 31)); // not drifting
    }

    function test_runPayment_flow() public {
        uint256 id = _createSchedule(vendor, 500 * U, Unit.MONTH, 1, start, 0);
        (uint256 run, uint64 dueAt) = vault.nextUnpaidRun(id);
        assertEq(run, 0);
        assertEq(dueAt, start);

        vm.expectEmit(true, true, true, true);
        emit SchedulesModule.ScheduledRunPaid(id, 0, vendor, 500 * U);
        _payRun(id, 0);
        assertEq(usdt.balanceOf(vendor), 500 * U);
        assertTrue(vault.paidRun(id, 0));

        (run, dueAt) = vault.nextUnpaidRun(id);
        assertEq(run, 1);
        assertEq(dueAt, DateTime.addMonths(start, 1));

        // run 1 is not due yet
        _payRunExpecting(id, 1, abi.encodeWithSelector(SchedulesModule.RunNotDue.selector, id, 1, dueAt));
        vm.warp(dueAt);
        _payRun(id, 1);
        assertEq(usdt.balanceOf(vendor), 1_000 * U);
    }

    function test_run_cannotBePaidTwice() public {
        uint256 id = _createSchedule(vendor, 500 * U, Unit.DAY, 1, start, 0);
        _payRun(id, 0);
        _payRunExpecting(id, 0, abi.encodeWithSelector(SchedulesModule.RunAlreadyPaid.selector, id, 0));
    }

    function test_run_needsFreshTierApprovals() public {
        uint256 id = _createSchedule(vendor, 1_500 * U, Unit.DAY, 1, start, 0); // 3 approvals per run
        uint64 vb = _vb();
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, 1, 3));
        vault.executeScheduledRun(id, 0, vb, _approvalsFor(vault, _hRun(id, 0, vb), 1));
        vault.executeScheduledRun(id, 0, vb, _approvalsFor(vault, _hRun(id, 0, vb), 3));
    }

    function test_run_signatureBoundToScheduleAndRun() public {
        uint256 id0 = _createSchedule(vendor, 100 * U, Unit.DAY, 1, start, 0);
        uint256 id1 = _createSchedule(vendor, 100 * U, Unit.DAY, 1, start, 0);
        vm.warp(block.timestamp + 5 days);
        uint64 vb = _vb();
        Approval[] memory forRun1 = _approvalsFor(vault, _hRun(id0, 1, vb), 1);
        vm.expectRevert(); // run 1 signatures cannot pay run 2
        vault.executeScheduledRun(id0, 2, vb, forRun1);
        vm.expectRevert(); // nor another schedule's run 1
        vault.executeScheduledRun(id1, 1, vb, forRun1);
        vault.executeScheduledRun(id0, 1, vb, forRun1);
    }

    function test_run_expiredApprovalsRevert() public {
        uint256 id = _createSchedule(vendor, 100 * U, Unit.DAY, 1, start, 0);
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hRun(id, 0, vb), 1);
        vm.warp(vb + 1);
        vm.expectRevert(ApprovalsModule.Expired.selector);
        vault.executeScheduledRun(id, 0, vb, a);
    }

    function test_run_outOfOrder_pointerAdvances() public {
        uint256 id = _createSchedule(vendor, 10 * U, Unit.DAY, 1, start, 0);
        vm.warp(block.timestamp + 10 days);
        _payRun(id, 2);
        (uint256 run,) = vault.nextUnpaidRun(id);
        assertEq(run, 0);
        _payRun(id, 0);
        (run,) = vault.nextUnpaidRun(id);
        assertEq(run, 1);
        _payRun(id, 1);
        (run,) = vault.nextUnpaidRun(id); // jumps past the already-paid run 2
        assertEq(run, 3);
    }

    function test_run_budgetEnforced() public {
        // 60,000 per run against a 100,000 monthly budget: second run in the same month is rejected
        uint256 id = _createSchedule(vendor, 60_000 * U, Unit.DAY, 1, start, 0);
        vm.warp(block.timestamp + 1 days);
        _payRun(id, 0);
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hRun(id, 1, vb), 5);
        vm.expectRevert(abi.encodeWithSelector(BudgetsModule.BudgetExceeded.selector, GENERAL, 60_000 * U, 40_000 * U));
        vault.executeScheduledRun(id, 1, vb, a);
    }

    function test_run_afterEndReverts() public {
        uint64 end = start + 2 days;
        uint256 id = _createSchedule(vendor, 10 * U, Unit.DAY, 1, start, end);
        vm.warp(block.timestamp + 10 days);
        _payRun(id, 2); // due exactly at end: allowed
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hRun(id, 3, vb), 1);
        vm.expectRevert(abi.encodeWithSelector(SchedulesModule.ScheduleEnded.selector, id, 3));
        vault.executeScheduledRun(id, 3, vb, a);
    }

    function test_run_failsIfPayeeRemoved() public {
        uint256 id = _createSchedule(vendor, 10 * U, Unit.DAY, 1, start, 0);
        _gov(uint8(9), abi.encode(vendor)); // RemovePayee
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hRun(id, 0, vb), 1);
        vm.expectRevert(abi.encodeWithSelector(PaymentsModule.PayeeNotRegistered.selector, vendor));
        vault.executeScheduledRun(id, 0, vb, a);
    }

    function test_cancel_needsOneApprovalAndStopsRuns() public {
        uint256 id = _createSchedule(vendor, 10 * U, Unit.DAY, 1, start, 0);
        uint256 n = _nonce();
        uint64 vb = _vb();
        vm.expectRevert();
        vault.cancelSchedule(id, n, vb, new Approval[](0));
        vault.cancelSchedule(id, n, vb, _approvalsFor(vault, _hCancel(id, n, vb), 1));
        assertFalse(vault.getSchedule(id).active);

        (, uint64 dueAt) = vault.nextUnpaidRun(id);
        assertEq(dueAt, 0);

        uint64 vb2 = _vb();
        Approval[] memory a = _approvalsFor(vault, _hRun(id, 0, vb2), 1);
        vm.expectRevert(abi.encodeWithSelector(SchedulesModule.ScheduleInactive.selector, id));
        vault.executeScheduledRun(id, 0, vb2, a);

        // cancelling twice is rejected
        uint256 n2 = _nonce();
        Approval[] memory c = _approvalsFor(vault, _hCancel(id, n2, vb), 1);
        vm.expectRevert(abi.encodeWithSelector(SchedulesModule.ScheduleInactive.selector, id));
        vault.cancelSchedule(id, n2, vb, c);
    }

    function test_unknownSchedule() public {
        vm.expectRevert(abi.encodeWithSelector(SchedulesModule.ScheduleNotFound.selector, 7));
        vault.getSchedule(7);
        vm.expectRevert(abi.encodeWithSelector(SchedulesModule.ScheduleNotFound.selector, 7));
        vault.nextUnpaidRun(7);
        vm.expectRevert(abi.encodeWithSelector(SchedulesModule.ScheduleNotFound.selector, 7));
        vault.executeScheduledRun(7, 0, _vb(), new Approval[](0));
    }
}
