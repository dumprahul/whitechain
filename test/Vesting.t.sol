// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/Base.t.sol";
import {DateTime} from "../src/libs/DateTime.sol";
import {ApprovalsModule} from "../src/modules/ApprovalsModule.sol";
import {BudgetsModule} from "../src/modules/BudgetsModule.sol";
import {PaymentsModule} from "../src/modules/PaymentsModule.sol";
import {VestingModule} from "../src/modules/VestingModule.sol";
import {YieldModule} from "../src/modules/YieldModule.sol";
import {Approval, GovAction, Payment, Vesting, VestingCreateData} from "../src/OrgTypes.sol";

contract VestingTest is BaseTest {
    uint256 internal constant TOTAL = 12_000 * U;

    function _revoke(uint256 id, uint64 effectiveAt) internal {
        _gov(uint8(GovAction.RevokeVesting), abi.encode(id, effectiveAt));
    }

    function _monthsFromNow(uint256 start, uint256 m) internal pure returns (uint256) {
        return DateTime.addMonths(start, m);
    }

    function test_create_reservesFundsAndSpendsBudget() public {
        uint256 availBefore = vault.availableToSpend();
        uint256 id = _createVesting(employee, TOTAL, 12, 48, 1, true);
        assertEq(id, 0);
        assertEq(vault.reservedVesting(), TOTAL);
        assertEq(vault.availableToSpend(), availBefore - TOTAL);
        assertEq(vault.totalAssets(), 1_000_000 * U); // still in the vault
        (, uint256 spent,,) = vault.budgetStatus(COMP);
        assertEq(spent, TOTAL);
        Vesting memory v = vault.getVesting(id);
        assertEq(v.beneficiary, employee);
        assertEq(v.total, TOTAL);
        assertTrue(v.revocable);
    }

    function test_create_needsTierApprovals() public {
        VestingCreateData memory v = VestingCreateData(
            employee, TOTAL, uint64(block.timestamp), 0, 12, 1, false, COMP, bytes32(0), _nonce(), _vb()
        );
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, 4, 5));
        vault.createVesting(v, _approvalsFor(vault, _hVesting(v), 4));
        vault.createVesting(v, _approvalsFor(vault, _hVesting(v), 5));
    }

    function test_create_invalidParams() public {
        uint64 s = uint64(block.timestamp);
        _expectBadVesting(0, s, 0, 12, 1); // zero total
        _expectBadVesting(100 * U, 0, 0, 12, 1); // zero start
        _expectBadVesting(100 * U, s, 0, 0, 0); // zero duration
        _expectBadVesting(100 * U, s, 0, 121, 1); // longer than 10 years
        _expectBadVesting(100 * U, s, 13, 12, 1); // cliff after end
        _expectBadVesting(100 * U, s, 0, 12, 5); // duration not divisible by step
    }

    function _expectBadVesting(uint256 total, uint64 s, uint16 cliff, uint16 dur, uint16 step) internal {
        VestingCreateData memory v =
            VestingCreateData(employee, total, s, cliff, dur, step, false, COMP, bytes32(0), _nonce(), _vb());
        vm.expectRevert(VestingModule.InvalidVestingParams.selector);
        vault.createVesting(v, _approvalsFor(vault, _hVesting(v), 5));
    }

    function test_create_beneficiaryMustBePayee() public {
        VestingCreateData memory v = VestingCreateData(
            stranger, 100 * U, uint64(block.timestamp), 0, 12, 1, false, COMP, bytes32(0), _nonce(), _vb()
        );
        vm.expectRevert(abi.encodeWithSelector(PaymentsModule.PayeeNotRegistered.selector, stranger));
        vault.createVesting(v, _approvalsFor(vault, _hVesting(v), 1));
    }

    function test_create_budgetEnforced() public {
        VestingCreateData memory v = VestingCreateData(
            employee, 1_000_001 * U, uint64(block.timestamp), 0, 12, 1, false, COMP, bytes32(0), _nonce(), _vb()
        );
        vm.expectRevert();
        vault.createVesting(v, _approvalsFor(vault, _hVesting(v), 5));
    }

    function test_create_cannotExceedAvailable() public {
        _pay(vendor, 100_000 * U); // vault now holds 900,000
        _createVesting(employee, 800_000 * U, 0, 12, 1, false);
        // 100,000 left unreserved: another grant of 100,001 does not fit
        VestingCreateData memory v = VestingCreateData(
            employee, 100_001 * U, uint64(block.timestamp), 0, 12, 1, false, COMP, bytes32(0), _nonce(), _vb()
        );
        uint256 n = vault.approvalsRequired(100_001 * U);
        vm.expectRevert(abi.encodeWithSelector(YieldModule.InsufficientAvailable.selector, 100_001 * U, 100_000 * U));
        vault.createVesting(v, _approvalsFor(vault, _hVesting(v), n));
    }

    function test_reservedFundsCannotBeSpentByPayments() public {
        _createVesting(employee, 995_000 * U, 0, 12, 1, false);
        assertEq(vault.availableToSpend(), 5_000 * U);
        Payment memory p = _newPayment(vendor, 5_000 * U + 1);
        vm.expectRevert(abi.encodeWithSelector(YieldModule.InsufficientAvailable.selector, 5_000 * U + 1, 5_000 * U));
        vault.executePayment(p, _signedPayment(p, 5));
        _pay(vendor, 5_000 * U); // exactly the free part works
        assertEq(vault.availableToSpend(), 0);
        assertEq(vault.totalAssets(), vault.reservedVesting());
    }

    function test_noReleaseBeforeCliff() public {
        uint256 id = _createVesting(employee, TOTAL, 12, 48, 1, false);
        assertEq(vault.vestedAmount(id), 0);
        vm.warp(DateTime.addMonths(block.timestamp, 12) - 1);
        assertEq(vault.releasable(id), 0);
        vm.expectRevert(abi.encodeWithSelector(VestingModule.NothingToRelease.selector, id));
        vault.release(id);
    }

    function test_steppedMonthly_schedule() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 12, 48, 1, false);

        vm.warp(DateTime.addMonths(start, 12)); // cliff: 12/48
        assertEq(vault.vestedAmount(id), TOTAL * 12 / 48);
        vm.warp(DateTime.addMonths(start, 13) - 1);
        assertEq(vault.vestedAmount(id), TOTAL * 12 / 48);
        vm.warp(DateTime.addMonths(start, 13));
        assertEq(vault.vestedAmount(id), TOTAL * 13 / 48);
        vm.warp(DateTime.addMonths(start, 47));
        assertEq(vault.vestedAmount(id), TOTAL * 47 / 48);
        vm.warp(DateTime.addMonths(start, 48));
        assertEq(vault.vestedAmount(id), TOTAL);
        vm.warp(DateTime.addMonths(start, 100));
        assertEq(vault.vestedAmount(id), TOTAL);
    }

    function test_steppedQuarterly_schedule() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 0, 24, 3, false);
        vm.warp(DateTime.addMonths(start, 5)); // only 1 whole step (3 months) elapsed
        assertEq(vault.vestedAmount(id), TOTAL * 3 / 24);
        vm.warp(DateTime.addMonths(start, 6));
        assertEq(vault.vestedAmount(id), TOTAL * 6 / 24);
    }

    function test_continuousLinear_schedule() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 0, 12, 0, false);
        uint256 end = DateTime.addMonths(start, 12);
        vm.warp(start + (end - start) / 2);
        assertEq(vault.vestedAmount(id), TOTAL * ((end - start) / 2) / (end - start));
        vm.warp(start + 1 days);
        assertEq(vault.vestedAmount(id), TOTAL * 1 days / (end - start));
        vm.warp(end);
        assertEq(vault.vestedAmount(id), TOTAL);
    }

    function test_linearWithCliff_jumpsAtCliff() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 6, 12, 0, false);
        vm.warp(DateTime.addMonths(start, 6) - 1);
        assertEq(vault.vestedAmount(id), 0);
        uint256 cliffAt = DateTime.addMonths(start, 6);
        vm.warp(cliffAt);
        uint256 end = DateTime.addMonths(start, 12);
        assertEq(vault.vestedAmount(id), TOTAL * (cliffAt - start) / (end - start)); // roughly half
    }

    function test_release_isPermissionlessAndPaysOnlyBeneficiary() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 0, 12, 1, false);
        vm.warp(DateTime.addMonths(start, 3));
        vm.prank(stranger);
        vault.release(id);
        assertEq(usdt.balanceOf(employee), TOTAL * 3 / 12);
        assertEq(usdt.balanceOf(stranger), 0);
        assertEq(vault.reservedVesting(), TOTAL - TOTAL * 3 / 12);
        assertEq(vault.getVesting(id).released, TOTAL * 3 / 12);

        // nothing more to release until next step
        vm.expectRevert(abi.encodeWithSelector(VestingModule.NothingToRelease.selector, id));
        vault.release(id);

        vm.warp(DateTime.addMonths(start, 12));
        vault.release(id);
        assertEq(usdt.balanceOf(employee), TOTAL);
        assertEq(vault.reservedVesting(), 0);
    }

    function test_release_repeatedly_releasedNeverExceedsVested() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 0, 12, 1, false);
        for (uint256 m = 1; m <= 12; ++m) {
            vm.warp(DateTime.addMonths(start, m));
            vault.release(id);
            assertEq(vault.getVesting(id).released, vault.vestedAmount(id));
            assertLe(vault.vestedAmount(id), TOTAL);
        }
        assertEq(usdt.balanceOf(employee), TOTAL);
    }

    function test_release_unknownVesting() public {
        vm.expectRevert(abi.encodeWithSelector(VestingModule.VestingNotFound.selector, 3));
        vault.release(3);
    }

    function test_oneToTenYearDurations_fullyVestAtEnd() public {
        for (uint16 years_ = 1; years_ <= 10; ++years_) {
            uint256 start = block.timestamp;
            uint256 id = _createVesting(employee, 1_000 * U, 0, years_ * 12, 1, false);
            vm.warp(DateTime.addMonths(start, years_ * 12));
            assertEq(vault.vestedAmount(id), 1_000 * U);
            vm.warp(start); // rewind for next iteration (cheatcode only; contract time not read monotonic)
        }
    }

    function test_releaseDrawsFromYieldPool() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 0, 12, 1, false);
        // move almost everything into the pool
        vm.prank(platformOwner);
        pool.setApyBps(0);
        vault.sweep(); // minLiquid 10,000 stays, 500,000 cap
        assertEq(vault.liquidBalance(), 500_000 * U);
        assertEq(vault.poolBalance(), 500_000 * U);

        // drain liquid so the release must recall from the pool
        Payment memory p = Payment(0, vendor, 500_000 * U, COMP, bytes32(0), _nonce(), _vb());
        vault.executePayment(p, _signedPayment(p, 5));
        assertEq(vault.liquidBalance(), 0);

        vm.warp(DateTime.addMonths(start, 6));
        vault.release(id);
        assertEq(usdt.balanceOf(employee), TOTAL / 2);
        assertEq(vault.poolBalance(), 500_000 * U - TOTAL / 2);
    }

    // ----------------------------------------------------------- revocation

    function test_revoke_returnsUnvestedAndKeepsVestedClaimable() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 12, 48, 1, true);
        vm.warp(DateTime.addMonths(start, 18));
        uint256 availBefore = vault.availableToSpend();

        _revoke(id, uint64(block.timestamp));
        uint256 vested = TOTAL * 18 / 48;
        assertTrue(vault.getVesting(id).revoked);
        assertEq(vault.vestedAmount(id), vested);
        assertEq(vault.reservedVesting(), vested);
        assertEq(vault.availableToSpend(), availBefore + (TOTAL - vested));

        vault.release(id);
        assertEq(usdt.balanceOf(employee), vested);
        assertEq(vault.reservedVesting(), 0);

        // no more vesting after revoke
        vm.warp(DateTime.addMonths(start, 60));
        assertEq(vault.vestedAmount(id), vested);
        vm.expectRevert(abi.encodeWithSelector(VestingModule.NothingToRelease.selector, id));
        vault.release(id);
    }

    function test_revoke_retroactiveEffectiveTime() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 12, 48, 1, true);
        vm.warp(DateTime.addMonths(start, 20));
        _revoke(id, uint64(DateTime.addMonths(start, 14))); // effective 6 months ago
        assertEq(vault.vestedAmount(id), TOTAL * 14 / 48);
        assertEq(vault.reservedVesting(), TOTAL * 14 / 48);
    }

    function test_revoke_beforeCliffReturnsEverything() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 12, 48, 1, true);
        vm.warp(DateTime.addMonths(start, 6));
        _revoke(id, uint64(block.timestamp));
        assertEq(vault.vestedAmount(id), 0);
        assertEq(vault.reservedVesting(), 0);
    }

    function test_revoke_afterPartialReleaseNeverClawsBack() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 0, 12, 1, true);
        vm.warp(DateTime.addMonths(start, 6));
        vault.release(id);
        uint256 released = vault.getVesting(id).released;
        // revoke with an effective time earlier than what was already released
        _revoke(id, uint64(DateTime.addMonths(start, 2)));
        assertEq(vault.vestedAmount(id), released);
        assertEq(vault.reservedVesting(), 0);
        assertLe(vault.vestedAmount(id), TOTAL);
    }

    function test_revoke_rules() public {
        uint256 fixedId = _createVesting(employee, 100 * U, 0, 12, 1, false);
        _expectGovRevertVesting(
            fixedId, uint64(block.timestamp), abi.encodeWithSelector(VestingModule.NotRevocable.selector, fixedId)
        );

        uint256 id = _createVesting(employee, 100 * U, 0, 12, 1, true);
        _expectGovRevertVesting(
            id, uint64(block.timestamp + 1), abi.encodeWithSelector(VestingModule.InvalidRevokeTime.selector)
        );
        _revoke(id, uint64(block.timestamp));
        _expectGovRevertVesting(
            id, uint64(block.timestamp), abi.encodeWithSelector(VestingModule.AlreadyRevoked.selector, id)
        );
        _expectGovRevertVesting(
            99, uint64(block.timestamp), abi.encodeWithSelector(VestingModule.VestingNotFound.selector, 99)
        );
    }

    function _expectGovRevertVesting(uint256 id, uint64 eff, bytes memory err) internal {
        bytes memory data = abi.encode(id, eff);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        uint8 action = uint8(GovAction.RevokeVesting);
        Approval[] memory a = _approvalsFor(vault, _hGov(action, data, nonce, vb), 5);
        vm.expectRevert(err);
        vault.executeGovernance(action, data, nonce, vb, a);
    }

    function test_revoke_needsGovernanceApprovals() public {
        uint256 id = _createVesting(employee, 100 * U, 0, 12, 1, true);
        bytes memory data = abi.encode(id, uint64(block.timestamp));
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        uint8 action = uint8(GovAction.RevokeVesting);
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, 3, 5));
        vault.executeGovernance(action, data, nonce, vb, _approvalsFor(vault, _hGov(action, data, nonce, vb), 3));
    }

    // -------------------------------------------------- beneficiary change

    function test_changeBeneficiary() public {
        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, 0, 12, 1, false);
        address newBen = makeAddr("newBen");
        _gov(uint8(GovAction.AddPayee), abi.encode(newBen));
        _gov(uint8(GovAction.ChangeBeneficiary), abi.encode(id, newBen));
        assertEq(vault.getVesting(id).beneficiary, newBen);

        vm.warp(DateTime.addMonths(start, 12));
        vault.release(id);
        assertEq(usdt.balanceOf(newBen), TOTAL);
        assertEq(usdt.balanceOf(employee), 0);
    }

    function test_changeBeneficiary_mustBePayee() public {
        uint256 id = _createVesting(employee, TOTAL, 0, 12, 1, false);
        bytes memory data = abi.encode(id, stranger);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        uint8 action = uint8(GovAction.ChangeBeneficiary);
        vm.expectRevert(abi.encodeWithSelector(PaymentsModule.PayeeNotRegistered.selector, stranger));
        vault.executeGovernance(action, data, nonce, vb, _approvalsFor(vault, _hGov(action, data, nonce, vb), 5));
    }

    // ----------------------------------------------------------------- fuzz

    function _vestedAtTime(uint256 id, uint256 t) internal returns (uint256) {
        vm.warp(t);
        return vault.vestedAmount(id);
    }

    function testFuzz_vestedMonotonicAndBounded(uint16 duration, uint16 cliff, uint16 step, uint32 t1, uint32 t2)
        public
    {
        duration = uint16(bound(duration, 1, 120));
        cliff = uint16(bound(cliff, 0, duration));
        // pick a step that divides the duration (or 0)
        uint16[8] memory candidates = [uint16(0), 1, 2, 3, 4, 6, 12, duration];
        step = candidates[step % 8];
        if (step != 0 && duration % step != 0) step = 1;

        uint256 start = block.timestamp;
        uint256 id = _createVesting(employee, TOTAL, cliff, duration, step, false);

        t1 = uint32(bound(t1, 0, 11 * 365 days));
        t2 = uint32(bound(t2, 0, 11 * 365 days));
        (uint256 lo, uint256 hi) = t1 <= t2 ? (uint256(t1), uint256(t2)) : (uint256(t2), uint256(t1));

        uint256 vLo = _vestedAtTime(id, start + lo);
        uint256 vHi = _vestedAtTime(id, start + hi);
        assertLe(vLo, vHi, "vested must never decrease");
        assertLe(vHi, TOTAL, "vested <= total");
        if (start + hi >= DateTime.addMonths(start, duration)) assertEq(vHi, TOTAL);
        if (start + hi < DateTime.addMonths(start, cliff)) assertEq(vHi, 0);
    }
}
