// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BaseTest} from "./utils/Base.t.sol";
import {Sig} from "./utils/Sig.sol";
import {OrgVault} from "../src/OrgVault.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {Approval, GovAction, Payment, Vesting, VestingCreateData} from "../src/OrgTypes.sol";

/// @dev Fuzzed actor: performs bounded random actions against the vault, always with valid approvals.
contract VaultHandler is Sig {
    OrgVault public vault;
    MockUSDT public usdt;
    uint256[] internal pks;
    address internal vendor;
    address internal employee;
    bytes32 internal constant GENERAL = keccak256("GENERAL");
    bytes32 internal constant COMP = keccak256("COMPENSATION");

    uint256 internal nonce;
    uint256 public ghostDeposited;
    uint256 public vestingIds;
    uint256 public okPay;
    uint256 public okRelease;
    uint256 public okRevoke;
    uint256 public okSweep;
    uint256 public okRecall;

    constructor(OrgVault vault_, MockUSDT usdt_, uint256[] memory pks_, address vendor_, address employee_) {
        vault = vault_;
        usdt = usdt_;
        pks = pks_;
        vendor = vendor_;
        employee = employee_;
    }

    function pay(uint256 amount, bool toEmployee, bool comp) external {
        amount = bound(amount, 1, 3_000 * 1e6);
        Payment memory p = Payment(
            toEmployee ? 1 : 0,
            toEmployee ? employee : vendor,
            amount,
            comp ? COMP : GENERAL,
            bytes32(0),
            ++nonce,
            uint64(block.timestamp + 1 days)
        );
        try vault.executePayment(p, _sign(address(vault), _hPayment(p), pks, vault.approvalsRequired(amount))) {
            ++okPay;
        } catch {}
    }

    function vest(uint256 total, uint256 duration, uint256 cliff, bool stepped) external {
        total = bound(total, 1, 20_000 * 1e6);
        duration = bound(duration, 1, 60);
        cliff = bound(cliff, 0, duration);
        VestingCreateData memory v = VestingCreateData({
            beneficiary: employee,
            total: total,
            start: uint64(block.timestamp),
            cliffMonths: uint16(cliff),
            durationMonths: uint16(duration),
            stepMonths: stepped ? 1 : 0,
            revocable: true,
            budgetId: COMP,
            ref: bytes32(0),
            nonce: ++nonce,
            validBefore: uint64(block.timestamp + 1 days)
        });
        try vault.createVesting(v, _sign(address(vault), _hVesting(v), pks, vault.approvalsRequired(total))) {
            ++vestingIds;
        } catch {}
    }

    function release(uint256 seed) external {
        if (vestingIds == 0) return;
        try vault.release(seed % vestingIds) {
            ++okRelease;
        } catch {}
    }

    function revoke(uint256 seed) external {
        if (vestingIds == 0) return;
        bytes memory data = abi.encode(seed % vestingIds, uint64(block.timestamp));
        uint8 action = uint8(GovAction.RevokeVesting);
        uint64 vb = uint64(block.timestamp + 1 days);
        ++nonce;
        try vault.executeGovernance(
            action, data, nonce, vb, _sign(address(vault), _hGov(action, data, nonce, vb), pks, 5)
        ) {
            ++okRevoke;
        } catch {}
    }

    function sweep() external {
        try vault.sweep() {
            ++okSweep;
        } catch {}
    }

    function recall(uint256 amount) external {
        amount = bound(amount, 1, 40_000 * 1e6);
        uint64 vb = uint64(block.timestamp + 1 days);
        ++nonce;
        try vault.recall(amount, nonce, vb, _sign(address(vault), _hRecall(amount, nonce, vb), pks, 1)) {
            ++okRecall;
        } catch {}
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 200_000 * 1e6);
        usdt.mint(address(vault), amount);
        ghostDeposited += amount;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 120 days));
    }
}

contract InvariantsTest is StdInvariant, BaseTest {
    VaultHandler internal handler;
    uint256 internal initialAssets;
    address[] internal approversAtStart;
    mapping(uint256 => uint256) internal lastVested;

    function setUp() public override {
        super.setUp();
        initialAssets = vault.totalAssets();
        approversAtStart = approvers;
        handler = new VaultHandler(vault, usdt, pks, vendor, employee);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = VaultHandler.pay.selector;
        sel[1] = VaultHandler.vest.selector;
        sel[2] = VaultHandler.release.selector;
        sel[3] = VaultHandler.revoke.selector;
        sel[4] = VaultHandler.sweep.selector;
        sel[5] = VaultHandler.recall.selector;
        sel[6] = VaultHandler.deposit.selector;
        sel[7] = VaultHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function afterInvariant() public view {
        console.log("ok pay/vest/release:", handler.okPay(), handler.vestingIds(), handler.okRelease());
        console.log("ok revoke/sweep/recall:", handler.okRevoke(), handler.okSweep(), handler.okRecall());
    }

    /// Inv 3: reserved vesting funds are always backed by assets.
    function invariant_reservedIsBacked() public view {
        assertLe(vault.reservedVesting(), vault.totalAssets());
    }

    /// Inv 4: released <= vested <= total, and vested never decreases.
    function invariant_vestingBounds() public {
        uint256 n = vault.vestingCount();
        for (uint256 i; i < n; ++i) {
            Vesting memory v = vault.getVesting(i);
            uint256 vested = vault.vestedAmount(i);
            assertLe(v.released, vested, "released <= vested");
            assertLe(vested, v.total, "vested <= total");
            assertGe(vested, lastVested[i], "vested is monotonic");
            lastVested[i] = vested;
        }
    }

    /// reservedVesting equals the sum of what every grant still owes its beneficiary.
    function invariant_reservedEqualsOutstandingGrants() public view {
        uint256 owed;
        uint256 n = vault.vestingCount();
        for (uint256 i; i < n; ++i) {
            Vesting memory v = vault.getVesting(i);
            uint256 entitlement = v.revoked ? vault.vestedAmount(i) : v.total;
            owed += entitlement - v.released;
        }
        assertEq(vault.reservedVesting(), owed);
    }

    /// Inv 5: spend in a budget window never exceeds its limit.
    function invariant_budgetsNeverExceeded() public view {
        (uint256 limit, uint256 spent,,) = vault.budgetStatus(GENERAL);
        assertLe(spent, limit);
        (limit, spent,,) = vault.budgetStatus(COMP);
        assertLe(spent, limit);
    }

    /// Inv 1: USDT only leaves through the audited paths. With a 0% pool, every token is either still in the
    /// vault system or sits with a payee/beneficiary.
    function invariant_fundsConserved() public view {
        uint256 paidOut = usdt.balanceOf(vendor) + usdt.balanceOf(employee);
        assertEq(vault.totalAssets() + paidOut, initialAssets + handler.ghostDeposited());
    }

    /// Inv 7 (and approver safety): nothing the platform or fuzzed callers do changes the approver set.
    function invariant_approverSetUnchanged() public view {
        address[] memory now_ = vault.getApprovers();
        assertEq(now_.length, approversAtStart.length);
        for (uint256 i; i < now_.length; ++i) {
            assertEq(now_[i], approversAtStart[i]);
        }
    }
}
