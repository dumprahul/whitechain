// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Sig} from "./Sig.sol";
import {OrgFactory} from "../../src/OrgFactory.sol";
import {OrgVault} from "../../src/OrgVault.sol";
import {MockUSDT} from "../../src/mocks/MockUSDT.sol";
import {MockAavePool} from "../../src/mocks/MockAavePool.sol";
import {
    Approval,
    BudgetInit,
    GovAction,
    OrgInit,
    Payment,
    ScheduleCreateData,
    SweepConfig,
    Tier,
    Unit,
    VestingCreateData
} from "../../src/OrgTypes.sol";

/// @dev Shared fixture: mock USDT/pool, factory, implementation and one default vault with five approvers.
abstract contract BaseTest is Sig {
    uint256 internal constant U = 1e6; // 1 USDT
    uint256 internal constant T0 = 1736942400; // 2025-01-15 12:00:00 UTC
    bytes32 internal constant GENERAL = keccak256("GENERAL");
    bytes32 internal constant COMP = keccak256("COMPENSATION");

    MockUSDT internal usdt;
    MockAavePool internal pool;
    OrgFactory internal factory;
    OrgVault internal impl;
    OrgVault internal vault;

    address internal platformOwner = makeAddr("platformOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal vendor = makeAddr("vendor");
    address internal employee = makeAddr("employee");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    uint256 internal payerPk = 0xBEEF;
    address internal payer;

    uint256[] internal pks; // sorted by address
    address[] internal approvers; // same order as pks
    uint256 internal nonceCounter;

    function setUp() public virtual {
        vm.warp(T0);
        payer = vm.addr(payerPk);

        usdt = new MockUSDT();
        pool = new MockAavePool(address(usdt), 6, platformOwner);
        factory = new OrgFactory(address(usdt), 5 * U, feeRecipient, platformOwner);
        impl = new OrgVault(address(factory), address(usdt), address(pool), address(pool.aToken()), 1 * U);
        vm.prank(platformOwner);
        factory.setImplementation(address(impl));

        _makeApprovers(5);
        vault = _createOrg(_defaultInit(), bytes32(uint256(1)));
        usdt.mint(address(vault), 1_000_000 * U);
    }

    // -------------------------------------------------------------- fixtures

    function _makeApprovers(uint256 n) internal {
        delete pks;
        delete approvers;
        for (uint256 i; i < n; ++i) {
            pks.push(0xA11CE00 + i);
        }
        // insertion sort by address
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = i; j > 0 && vm.addr(pks[j - 1]) > vm.addr(pks[j]); --j) {
                (pks[j - 1], pks[j]) = (pks[j], pks[j - 1]);
            }
        }
        for (uint256 i; i < n; ++i) {
            approvers.push(vm.addr(pks[i]));
        }
    }

    function _defaultTiers() internal pure returns (Tier[] memory t) {
        t = new Tier[](3);
        t[0] = Tier(999_990_000, 1); // up to 999.99 USDT
        t[1] = Tier(5_000 * 1e6, 3); // up to 5,000.00 USDT
        t[2] = Tier(type(uint128).max, 5);
    }

    function _defaultInit() internal view returns (OrgInit memory init) {
        init.approvers = approvers;
        init.tiers = _defaultTiers();
        init.payeeApprovals = 3;
        init.governanceApprovals = 5;
        init.budgets = new BudgetInit[](2);
        init.budgets[0] = BudgetInit(GENERAL, uint128(100_000 * U), 1);
        init.budgets[1] = BudgetInit(COMP, uint128(1_000_000 * U), 0);
        init.sweep = SweepConfig(true, uint128(10_000 * U), uint128(500_000 * U));
        init.payees = new address[](2);
        init.payees[0] = vendor;
        init.payees[1] = employee;
        init.metadataHash = keccak256("metadata");
    }

    function _authFor(address from, OrgInit memory init, bytes32 salt, uint256 pk)
        internal
        view
        returns (OrgFactory.Auth memory auth)
    {
        uint64 validAfter = 0;
        uint64 validBefore = uint64(block.timestamp + 1 hours);
        bytes32 nonce = keccak256(abi.encode(block.chainid, address(factory), from, salt, keccak256(abi.encode(init))));
        bytes32 structHash = keccak256(
            abi.encode(usdt.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, address(factory), 5 * U, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdt.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        auth = OrgFactory.Auth(validAfter, validBefore, v, r, s);
    }

    function _createOrg(OrgInit memory init, bytes32 salt) internal returns (OrgVault) {
        usdt.mint(payer, 5 * U);
        OrgFactory.Auth memory auth = _authFor(payer, init, salt, payerPk);
        vm.prank(relayer);
        return OrgVault(factory.createOrg(payer, init, salt, auth));
    }

    // --------------------------------------------------------------- helpers

    function _nonce() internal returns (uint256) {
        return ++nonceCounter;
    }

    function _vb() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function _approvalsFor(OrgVault v, bytes32 structHash, uint256 n) internal view returns (Approval[] memory) {
        return _sign(address(v), structHash, pks, n);
    }

    function _newPayment(address to, uint256 amount) internal returns (Payment memory p) {
        p = Payment(0, to, amount, GENERAL, keccak256("invoice"), _nonce(), _vb());
    }

    function _signedPayment(Payment memory p, uint256 n) internal view returns (Approval[] memory) {
        return _approvalsFor(vault, _hPayment(p), n);
    }

    /// @dev Pays with exactly the required number of approvals.
    function _pay(address to, uint256 amount) internal returns (Payment memory p) {
        p = _newPayment(to, amount);
        vault.executePayment(p, _signedPayment(p, vault.approvalsRequired(amount)));
    }

    function _gov(uint8 action, bytes memory data) internal {
        uint256 n = _govCount(action);
        uint256 nonce = _nonce();
        uint64 vb = _vb();
        vault.executeGovernance(action, data, nonce, vb, _approvalsFor(vault, _hGov(action, data, nonce, vb), n));
    }

    function _govCount(uint8 action) internal view returns (uint256) {
        uint256 c = (action == uint8(GovAction.AddPayee) || action == uint8(GovAction.RemovePayee))
            ? vault.payeeApprovals()
            : vault.governanceApprovals();
        uint256 n = vault.approverCount();
        return c > n ? n : c;
    }

    function _createVesting(address ben, uint256 total, uint16 cliff, uint16 dur, uint16 step, bool revocable)
        internal
        returns (uint256 id)
    {
        VestingCreateData memory v = VestingCreateData({
            beneficiary: ben,
            total: total,
            start: uint64(block.timestamp),
            cliffMonths: cliff,
            durationMonths: dur,
            stepMonths: step,
            revocable: revocable,
            budgetId: COMP,
            ref: keccak256("grant"),
            nonce: _nonce(),
            validBefore: _vb()
        });
        id = vault.createVesting(v, _approvalsFor(vault, _hVesting(v), vault.approvalsRequired(total)));
    }

    function _newSchedule(address to, uint256 amount, Unit unit, uint16 every, uint64 start, uint64 end)
        internal
        returns (ScheduleCreateData memory s)
    {
        s = ScheduleCreateData({
            payee: to,
            amount: amount,
            start: start,
            end: end,
            unit: unit,
            every: every,
            budgetId: GENERAL,
            ref: keccak256("rent"),
            nonce: _nonce(),
            validBefore: _vb()
        });
    }

    function _createSchedule(address to, uint256 amount, Unit unit, uint16 every, uint64 start, uint64 end)
        internal
        returns (uint256 id)
    {
        ScheduleCreateData memory s = _newSchedule(to, amount, unit, every, start, end);
        id = vault.createSchedule(s, _approvalsFor(vault, _hSchedule(s), vault.approvalsRequired(amount)));
    }

    function _payRun(uint256 id, uint256 run) internal {
        _payRunExpecting(id, run, "");
    }

    /// @dev Pre-reads happen before `expectRevert` so they are not mistaken for the call under test.
    function _payRunExpecting(uint256 id, uint256 run, bytes memory err) internal {
        uint64 vb = _vb();
        uint256 amount = vault.getSchedule(id).amount;
        Approval[] memory a = _approvalsFor(vault, _hRun(id, run, vb), vault.approvalsRequired(amount));
        if (err.length != 0) vm.expectRevert(err);
        vault.executeScheduledRun(id, run, vb, a);
    }
}
