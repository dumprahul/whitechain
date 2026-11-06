// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/Base.t.sol";
import {OrgVault} from "../src/OrgVault.sol";
import {ApprovalsModule} from "../src/modules/ApprovalsModule.sol";
import {BudgetsModule} from "../src/modules/BudgetsModule.sol";
import {PaymentsModule} from "../src/modules/PaymentsModule.sol";
import {Approval, GovAction, OrgInit, Payment, SweepConfig, Tier} from "../src/OrgTypes.sol";

contract GovernanceTest is BaseTest {
    address internal newbie = makeAddr("newbie");
    address internal newPayee = makeAddr("newPayee");

    function _a(GovAction a) internal pure returns (uint8) {
        return uint8(a);
    }

    function test_addPayee_needsPayeeApprovals() public {
        bytes memory data = abi.encode(newPayee);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        bytes32 h = _hGov(_a(GovAction.AddPayee), data, nonce, vb);

        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, 2, 3));
        vault.executeGovernance(_a(GovAction.AddPayee), data, nonce, vb, _approvalsFor(vault, h, 2));
        vault.executeGovernance(_a(GovAction.AddPayee), data, nonce, vb, _approvalsFor(vault, h, 3));
        assertTrue(vault.isPayee(newPayee));

        _pay(newPayee, 10 * U); // now payable
    }

    function test_removePayee_blocksPayments() public {
        _gov(_a(GovAction.RemovePayee), abi.encode(vendor));
        assertFalse(vault.isPayee(vendor));
        Payment memory p = _newPayment(vendor, 10 * U);
        vm.expectRevert(abi.encodeWithSelector(PaymentsModule.PayeeNotRegistered.selector, vendor));
        vault.executePayment(p, _signedPayment(p, 1));
    }

    function test_addPayee_zeroAddressReverts() public {
        bytes memory data = abi.encode(address(0));
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        bytes32 h = _hGov(_a(GovAction.AddPayee), data, nonce, vb);
        vm.expectRevert();
        vault.executeGovernance(_a(GovAction.AddPayee), data, nonce, vb, _approvalsFor(vault, h, 3));
    }

    function test_ruleChanges_needGovernanceApprovals() public {
        bytes memory data = abi.encode(newbie);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        bytes32 h = _hGov(_a(GovAction.AddApprover), data, nonce, vb);
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, 4, 5));
        vault.executeGovernance(_a(GovAction.AddApprover), data, nonce, vb, _approvalsFor(vault, h, 4));
    }

    function test_governanceDataIsBound() public {
        bytes memory data = abi.encode(newbie);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hGov(_a(GovAction.AddApprover), data, nonce, vb), 5);
        // submit different data with the same signatures
        vm.expectRevert();
        vault.executeGovernance(_a(GovAction.AddApprover), abi.encode(stranger), nonce, vb, a);
        // submit a different action with the same signatures
        vm.expectRevert();
        vault.executeGovernance(_a(GovAction.AddPayee), data, nonce, vb, a);
    }

    function test_addApprover() public {
        _gov(_a(GovAction.AddApprover), abi.encode(newbie));
        assertTrue(vault.isApprover(newbie));
        assertEq(vault.approverCount(), 6);

        // the new approver's signature counts
        uint256 pk = 0x5151;
        _gov(_a(GovAction.AddApprover), abi.encode(vm.addr(pk)));
        Payment memory p = _newPayment(vendor, 10 * U);
        bytes32 d = _digest(address(vault), _hPayment(p));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        Approval[] memory a = new Approval[](1);
        a[0] = Approval(vm.addr(pk), abi.encodePacked(r, s, v));
        vault.executePayment(p, a);
    }

    function test_addApprover_invalid() public {
        _expectGovRevert(_a(GovAction.AddApprover), abi.encode(approvers[0]), ApprovalsModule.InvalidApprovers.selector);
        _expectGovRevert(_a(GovAction.AddApprover), abi.encode(address(0)), ApprovalsModule.InvalidApprovers.selector);
    }

    function test_removeApprover() public {
        address removed = approvers[2];
        _gov(_a(GovAction.RemoveApprover), abi.encode(removed));
        assertFalse(vault.isApprover(removed));
        assertEq(vault.approverCount(), 4);
        // top tier (5) is clamped to the 4 remaining approvers
        assertEq(vault.approvalsRequired(50_000 * U), 4);

        // the removed approver can no longer sign
        Payment memory p = _newPayment(vendor, 10 * U);
        Approval[] memory a = new Approval[](1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[2], _digest(address(vault), _hPayment(p)));
        a[0] = Approval(removed, abi.encodePacked(r, s, v));
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.NotApprover.selector, removed));
        vault.executePayment(p, a);
    }

    function test_removeApprover_notAnApproverReverts() public {
        _expectGovRevert(_a(GovAction.RemoveApprover), abi.encode(stranger), ApprovalsModule.InvalidApprovers.selector);
    }

    function test_removeLastApproverReverts() public {
        _makeApprovers(1);
        vault = _createOrg(_defaultInit(), bytes32(uint256(5)));
        _expectGovRevert(_a(GovAction.RemoveApprover), abi.encode(approvers[0]), ApprovalsModule.LastApprover.selector);
    }

    function test_setTiers() public {
        Tier[] memory t = new Tier[](2);
        t[0] = Tier(100 * 1e6, 2);
        t[1] = Tier(type(uint128).max, 4);
        _gov(_a(GovAction.SetTiers), abi.encode(t));
        assertEq(vault.getTiers().length, 2);
        assertEq(vault.approvalsRequired(100 * U), 2);
        assertEq(vault.approvalsRequired(100 * U + 1), 4);
    }

    function test_setTiers_invalidReverts() public {
        Tier[] memory t = new Tier[](1);
        t[0] = Tier(100, 1); // last tier not unbounded
        _expectGovRevert(_a(GovAction.SetTiers), abi.encode(t), ApprovalsModule.InvalidTiers.selector);
    }

    function test_setBudget_newAndExisting() public {
        bytes32 id = keccak256("MARKETING");
        _gov(_a(GovAction.SetBudget), abi.encode(id, uint128(1_000 * U), uint16(3)));
        (uint256 limit,, uint64 ws, uint64 we) = vault.budgetStatus(id);
        assertEq(limit, 1_000 * U);
        assertEq(ws, 1735689600); // 2025-01-01
        assertEq(we, 1743465600); // 2025-04-01 (quarterly)

        Payment memory p = Payment(0, vendor, 600 * U, id, bytes32(0), _nonce(), _vb());
        vault.executePayment(p, _signedPayment(p, 1));

        // raising the limit keeps what was already spent
        _gov(_a(GovAction.SetBudget), abi.encode(id, uint128(5_000 * U), uint16(3)));
        (limit, ,, ) = vault.budgetStatus(id);
        (, uint256 spent,,) = vault.budgetStatus(id);
        assertEq(limit, 5_000 * U);
        assertEq(spent, 600 * U);
    }

    function test_setBudget_invalid() public {
        _expectGovRevert(
            _a(GovAction.SetBudget), abi.encode(bytes32(0), uint128(1), uint16(1)), BudgetsModule.InvalidBudget.selector
        );
        _expectGovRevert(
            _a(GovAction.SetBudget), abi.encode(keccak256("X"), uint128(1), uint16(121)), BudgetsModule.InvalidBudget.selector
        );
    }

    function test_setSweepConfig() public {
        _gov(_a(GovAction.SetSweepConfig), abi.encode(SweepConfig(false, 1, 2)));
        (bool enabled, uint128 minLiquid, uint128 maxInYield) = vault.sweepConfig();
        assertFalse(enabled);
        assertEq(minLiquid, 1);
        assertEq(maxInYield, 2);
    }

    function test_setGovernanceParams() public {
        _gov(_a(GovAction.SetGovernanceParams), abi.encode(uint8(2), uint8(3)));
        assertEq(vault.payeeApprovals(), 2);
        assertEq(vault.governanceApprovals(), 3);
        _expectGovRevert(
            _a(GovAction.SetGovernanceParams), abi.encode(uint8(0), uint8(3)), ApprovalsModule.InvalidGovernanceParams.selector
        );
    }

    function test_countsClampedForSmallOrgs() public {
        _makeApprovers(2);
        vault = _createOrg(_defaultInit(), bytes32(uint256(9))); // governance 5, payee 3 but only 2 approvers
        _gov(_a(GovAction.AddPayee), abi.encode(newPayee));
        assertTrue(vault.isPayee(newPayee));
        _gov(_a(GovAction.AddApprover), abi.encode(newbie));
        assertEq(vault.approverCount(), 3);
    }

    function test_invalidActionReverts() public {
        bytes memory data = "";
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        bytes32 h = _hGov(99, data, nonce, vb);
        vm.expectRevert(OrgVault.InvalidGovAction.selector);
        vault.executeGovernance(99, data, nonce, vb, _approvalsFor(vault, h, 5));
    }

    function test_governanceNonceReplayReverts() public {
        bytes memory data = abi.encode(newPayee);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hGov(_a(GovAction.AddPayee), data, nonce, vb), 3);
        vault.executeGovernance(_a(GovAction.AddPayee), data, nonce, vb, a);
        vm.expectRevert(ApprovalsModule.NonceUsed.selector);
        vault.executeGovernance(_a(GovAction.AddPayee), data, nonce, vb, a);
    }

    function _expectGovRevert(uint8 action, bytes memory data, bytes4 sel) internal {
        uint256 n = _govCount(action);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hGov(action, data, nonce, vb), n);
        vm.expectRevert(sel);
        vault.executeGovernance(action, data, nonce, vb, a);
    }
}
