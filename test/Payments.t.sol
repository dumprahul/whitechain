// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/Base.t.sol";
import {DateTime} from "../src/libs/DateTime.sol";
import {BudgetsModule} from "../src/modules/BudgetsModule.sol";
import {PaymentsModule} from "../src/modules/PaymentsModule.sol";
import {YieldModule} from "../src/modules/YieldModule.sol";
import {Payment} from "../src/OrgTypes.sol";

contract PaymentsTest is BaseTest {
    function test_invoicePayment() public {
        Payment memory p = _newPayment(vendor, 750 * U);
        vm.expectEmit(true, true, false, true);
        emit PaymentsModule.PaymentExecuted(0, vendor, 750 * U, GENERAL, p.ref, p.nonce);
        vm.prank(relayer);
        vault.executePayment(p, _signedPayment(p, 1));
        assertEq(usdt.balanceOf(vendor), 750 * U);
        assertEq(usdt.balanceOf(address(vault)), 1_000_000 * U - 750 * U);
        (uint256 limit, uint256 spent,,) = vault.budgetStatus(GENERAL);
        assertEq(limit, 100_000 * U);
        assertEq(spent, 750 * U);
    }

    function test_reimbursementPayment() public {
        Payment memory p = Payment(1, employee, 80 * U, GENERAL, keccak256("receipt"), _nonce(), _vb());
        vault.executePayment(p, _signedPayment(p, 1));
        assertEq(usdt.balanceOf(employee), 80 * U);
    }

    function test_invalidKindReverts() public {
        Payment memory p = Payment(2, vendor, 80 * U, GENERAL, bytes32(0), _nonce(), _vb());
        vm.expectRevert(PaymentsModule.InvalidKind.selector);
        vault.executePayment(p, _signedPayment(p, 1));
    }

    function test_unregisteredPayeeReverts() public {
        Payment memory p = _newPayment(stranger, 10 * U);
        vm.expectRevert(abi.encodeWithSelector(PaymentsModule.PayeeNotRegistered.selector, stranger));
        vault.executePayment(p, _signedPayment(p, 1));
    }

    function test_zeroAmountReverts() public {
        Payment memory p = _newPayment(vendor, 0);
        vm.expectRevert(YieldModule.ZeroAmount.selector);
        vault.executePayment(p, _signedPayment(p, 1));
    }

    function test_unknownBudgetReverts() public {
        Payment memory p = _newPayment(vendor, 10 * U);
        p.budgetId = keccak256("NOPE");
        vm.expectRevert(abi.encodeWithSelector(BudgetsModule.BudgetMissing.selector, p.budgetId));
        vault.executePayment(p, _signedPayment(p, 1));
    }

    function test_budget_exactLimitThenOverLimit() public {
        _pay(vendor, 50_000 * U);
        _pay(vendor, 50_000 * U); // exactly at the 100,000 limit
        (, uint256 spent,,) = vault.budgetStatus(GENERAL);
        assertEq(spent, 100_000 * U);

        Payment memory p = _newPayment(vendor, 1);
        vm.expectRevert(abi.encodeWithSelector(BudgetsModule.BudgetExceeded.selector, GENERAL, 1, 0));
        vault.executePayment(p, _signedPayment(p, 1));
    }

    function test_budget_rollsOverByCalendarMonth() public {
        _pay(vendor, 100_000 * U);
        (, uint256 spent, uint64 ws, uint64 we) = vault.budgetStatus(GENERAL);
        assertEq(spent, 100_000 * U);
        assertEq(ws, DateTime.timestampFromDate(2025, 1, 1));
        assertEq(we, DateTime.timestampFromDate(2025, 2, 1));

        // last second of January: still the same window
        vm.warp(we - 1);
        Payment memory p = _newPayment(vendor, 1 * U);
        vm.expectRevert();
        vault.executePayment(p, _signedPayment(p, 1));

        // first second of February: fresh window
        vm.warp(we);
        (, spent, ws, we) = vault.budgetStatus(GENERAL);
        assertEq(spent, 0);
        assertEq(ws, DateTime.timestampFromDate(2025, 2, 1));
        _pay(vendor, 100_000 * U);

        // and again two months later (skipping March entirely)
        vm.warp(DateTime.timestampFromDate(2025, 4, 3));
        _pay(vendor, 100_000 * U);
    }

    function test_budget_neverResetsWhenPeriodZero() public {
        // COMPENSATION has period 0 (1,000,000 total)
        Payment memory p = Payment(0, employee, 400_000 * U, COMP, bytes32(0), _nonce(), _vb());
        vault.executePayment(p, _signedPayment(p, 5));
        vm.warp(block.timestamp + 3650 days);
        Payment memory p2 = Payment(0, employee, 600_001 * U, COMP, bytes32(0), _nonce(), _vb());
        vm.expectRevert();
        vault.executePayment(p2, _signedPayment(p2, 5));
        (,,, uint64 end) = vault.budgetStatus(COMP);
        assertEq(end, type(uint64).max);
    }

    function test_budgetStatus_unknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BudgetsModule.BudgetMissing.selector, bytes32(uint256(1))));
        vault.budgetStatus(bytes32(uint256(1)));
    }

    function test_paymentLargerThanBalanceReverts() public {
        usdt.mint(address(0xdead), 0);
        // drain vault funds down using the compensation budget (no monthly cap)
        Payment memory p = Payment(0, employee, 1_000_000 * U, COMP, bytes32(0), _nonce(), _vb());
        vault.executePayment(p, _signedPayment(p, 5));
        Payment memory p2 = _newPayment(vendor, 1 * U);
        vm.expectRevert(abi.encodeWithSelector(YieldModule.InsufficientAvailable.selector, 1 * U, 0));
        vault.executePayment(p2, _signedPayment(p2, 1));
    }

    function testFuzz_budgetArithmetic(uint256 a, uint256 b) public {
        a = bound(a, 1, 100_000 * U);
        b = bound(b, 1, 100_000 * U);
        Payment memory p1 = _newPayment(vendor, a);
        vault.executePayment(p1, _signedPayment(p1, 5));
        Payment memory p2 = _newPayment(vendor, b);
        if (a + b > 100_000 * U) {
            vm.expectRevert(
                abi.encodeWithSelector(BudgetsModule.BudgetExceeded.selector, GENERAL, b, 100_000 * U - a)
            );
            vault.executePayment(p2, _signedPayment(p2, 5));
        } else {
            vault.executePayment(p2, _signedPayment(p2, 5));
            (, uint256 spent,,) = vault.budgetStatus(GENERAL);
            assertEq(spent, a + b);
        }
    }
}
