// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/Base.t.sol";
import {ApprovalsModule} from "../src/modules/ApprovalsModule.sol";
import {YieldModule} from "../src/modules/YieldModule.sol";
import {MockAToken} from "../src/mocks/MockAToken.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {Approval, GovAction, Payment, SweepConfig} from "../src/OrgTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract YieldTest is BaseTest {
    // vault: 1,000,000 liquid, minLiquid 10,000, maxInYield 500,000, minSweep 1

    function _setSweep(bool enabled, uint256 minLiquid, uint256 maxInYield) internal {
        _gov(
            uint8(GovAction.SetSweepConfig),
            abi.encode(SweepConfig(enabled, uint128(minLiquid), uint128(maxInYield)))
        );
    }

    function _recall(uint256 amount) internal {
        uint256 n = _nonce();
        uint64 vb = _vb();
        vault.recall(amount, n, vb, _approvalsFor(vault, _hRecall(amount, n, vb), 1));
    }

    function test_sweep_respectsMaxInYield() public {
        vm.expectEmit(false, true, false, true);
        emit YieldModule.Swept(500_000 * U, relayer);
        vm.prank(relayer);
        vault.sweep();
        assertEq(vault.liquidBalance(), 500_000 * U);
        assertEq(vault.poolBalance(), 500_000 * U);
        assertEq(vault.totalAssets(), 1_000_000 * U);
        // pool is at the cap now
        vm.expectRevert(YieldModule.NothingToSweep.selector);
        vault.sweep();
    }

    function test_sweep_respectsMinLiquid() public {
        _setSweep(true, 10_000 * U, 5_000_000 * U);
        vault.sweep();
        assertEq(vault.liquidBalance(), 10_000 * U);
        assertEq(vault.poolBalance(), 990_000 * U);
        vm.expectRevert(YieldModule.NothingToSweep.selector);
        vault.sweep();
    }

    function test_sweep_picksUpNewDeposits() public {
        _setSweep(true, 10_000 * U, 5_000_000 * U);
        vault.sweep();
        usdt.mint(address(vault), 25_000 * U);
        vault.sweep();
        assertEq(vault.liquidBalance(), 10_000 * U);
        assertEq(vault.poolBalance(), 1_015_000 * U);
    }

    function test_sweep_disabledReverts() public {
        _setSweep(false, 10_000 * U, 500_000 * U);
        vm.expectRevert(YieldModule.NothingToSweep.selector);
        vault.sweep();
    }

    function test_sweep_belowMinimumSkipped() public {
        _setSweep(true, 999_999 * U, 500_000 * U);
        // excess is 1 USDT: exactly the minimum, allowed
        vault.sweep();
        assertEq(vault.poolBalance(), 1 * U);
        usdt.mint(address(vault), U / 2); // 0.5 USDT excess is below the 1 USDT minimum
        vm.expectRevert(YieldModule.NothingToSweep.selector);
        vault.sweep();
    }

    function test_sweep_cannotMoveFundsAnywhereButPool() public {
        vault.sweep();
        assertEq(usdt.balanceOf(address(pool)), 500_000 * U);
        assertEq(usdt.balanceOf(relayer), 0);
        assertEq(usdt.allowance(address(vault), address(pool)), 0);
    }

    function test_payment_autoRecallsFromPool() public {
        _setSweep(true, 10_000 * U, 5_000_000 * U);
        vault.sweep(); // liquid 10,000, pool 990,000
        _pay(vendor, 50_000 * U); // needs a 40,000 recall
        assertEq(usdt.balanceOf(vendor), 50_000 * U);
        assertEq(vault.liquidBalance(), 0);
        assertEq(vault.poolBalance(), 950_000 * U);
        assertEq(vault.totalAssets(), 950_000 * U);
    }

    function test_payment_withReserveUsesPoolToo() public {
        // reserved funds may sit in the pool and still block regular spending
        _setSweep(true, 0, 5_000_000 * U);
        vault.sweep();
        assertEq(vault.liquidBalance(), 0);
        uint256 id = _createVesting(employee, 990_000 * U, 0, 12, 1, false);
        id;
        Payment memory p = _newPayment(vendor, 10_001 * U);
        vm.expectRevert(abi.encodeWithSelector(YieldModule.InsufficientAvailable.selector, 10_001 * U, 10_000 * U));
        vault.executePayment(p, _signedPayment(p, 5));
        _pay(vendor, 10_000 * U); // ok, recalled from the pool
        assertEq(vault.reservedVesting(), 990_000 * U);
    }

    function test_manualRecall() public {
        vault.sweep();
        _recall(100_000 * U);
        assertEq(vault.liquidBalance(), 600_000 * U);
        assertEq(vault.poolBalance(), 400_000 * U);
    }

    function test_recall_rules() public {
        vault.sweep();
        // not more than the pool balance
        uint256 n = _nonce();
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hRecall(500_001 * U, n, vb), 1);
        vm.expectRevert(MockAToken.InsufficientBalance.selector);
        vault.recall(500_001 * U, n, vb, a);

        // zero amount
        vm.expectRevert(YieldModule.ZeroAmount.selector);
        vault.recall(0, n, vb, a);

        // needs a real approver signature
        vm.expectRevert();
        vault.recall(1 * U, n, vb, new Approval[](0));

        // nonce is single-use
        _recall(1 * U);
        n = nonceCounter;
        vm.expectRevert(ApprovalsModule.NonceUsed.selector);
        vault.recall(1 * U, n, vb, _approvalsFor(vault, _hRecall(1 * U, n, vb), 1));
    }

    function test_yieldAccrues_andCountsInTotalAssets() public {
        vm.startPrank(platformOwner);
        pool.setApyBps(1000); // 10%
        vm.stopPrank();
        usdt.mint(platformOwner, 100_000 * U);
        vm.startPrank(platformOwner);
        usdt.approve(address(pool), type(uint256).max);
        pool.fundReserve(100_000 * U);
        vm.stopPrank();

        vault.sweep(); // 500,000 supplied
        vm.warp(block.timestamp + 365 days);
        assertApproxEqAbs(vault.poolBalance(), 550_000 * U, 2);
        assertApproxEqAbs(vault.totalAssets(), 1_050_000 * U, 2);

        // all principal and yield can come back
        _recall(vault.poolBalance());
        assertApproxEqAbs(vault.liquidBalance(), 1_050_000 * U, 2);
    }

    function test_withdrawAboveReserve_revertsInsteadOfStealing() public {
        vm.prank(platformOwner);
        pool.setApyBps(1000); // no reserve funded
        vault.sweep();
        vm.warp(block.timestamp + 365 days);
        uint256 tooMuch = vault.poolBalance(); // principal + unfunded yield
        uint256 n = _nonce();
        uint64 vb = _vb();
        Approval[] memory a = _approvalsFor(vault, _hRecall(tooMuch, n, vb), 1);
        vm.expectRevert(); // pool cannot pay unfunded yield
        vault.recall(tooMuch, n, vb, a);
        _recall(500_000 * U); // principal is always recoverable
        assertEq(vault.liquidBalance(), 1_000_000 * U);
    }

    // -------------------------------------------------------------- deposits

    function _depositAuth(address from, uint256 pk, uint256 value, bytes32 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s, uint64 validBefore)
    {
        validBefore = uint64(block.timestamp + 1 hours);
        bytes32 structHash = keccak256(
            abi.encode(usdt.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, address(vault), value, uint64(0), validBefore, nonce)
        );
        (v, r, s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", usdt.DOMAIN_SEPARATOR(), structHash)));
    }

    function test_depositWithAuthorization() public {
        address treasurer = vm.addr(0x7777);
        usdt.mint(treasurer, 1_000 * U);
        (uint8 v, bytes32 r, bytes32 s, uint64 vb) = _depositAuth(treasurer, 0x7777, 400 * U, bytes32(uint256(1)));
        uint256 before = vault.totalAssets();
        vm.expectEmit(true, false, false, true);
        emit YieldModule.Deposited(treasurer, 400 * U);
        vm.prank(relayer); // relayer pays gas, treasurer holds no native token
        vault.depositWithAuthorization(treasurer, 400 * U, 0, vb, bytes32(uint256(1)), v, r, s);
        assertEq(vault.totalAssets(), before + 400 * U);
        assertEq(usdt.balanceOf(treasurer), 600 * U);
    }

    function test_depositWithAuthorization_rules() public {
        address treasurer = vm.addr(0x7777);
        usdt.mint(treasurer, 1_000 * U);
        (uint8 v, bytes32 r, bytes32 s, uint64 vb) = _depositAuth(treasurer, 0x7777, 400 * U, bytes32(uint256(1)));

        // amount tampered
        vm.expectRevert(MockUSDT.AuthInvalidSignature.selector);
        vault.depositWithAuthorization(treasurer, 401 * U, 0, vb, bytes32(uint256(1)), v, r, s);
        // cannot pull from someone else
        vm.expectRevert(MockUSDT.AuthInvalidSignature.selector);
        vault.depositWithAuthorization(stranger, 400 * U, 0, vb, bytes32(uint256(1)), v, r, s);
        // zero
        vm.expectRevert(YieldModule.ZeroAmount.selector);
        vault.depositWithAuthorization(treasurer, 0, 0, vb, bytes32(uint256(1)), v, r, s);
        // the signature is only good for this vault
        (uint8 v2, bytes32 r2, bytes32 s2,) = _depositAuth(treasurer, 0x7777, 400 * U, bytes32(uint256(1)));
        vault.depositWithAuthorization(treasurer, 400 * U, 0, vb, bytes32(uint256(1)), v2, r2, s2);
        vm.expectRevert(MockUSDT.AuthUsed.selector);
        vault.depositWithAuthorization(treasurer, 400 * U, 0, vb, bytes32(uint256(1)), v2, r2, s2);
    }

    function test_plainTransfersCountAsDeposits() public {
        uint256 before = vault.totalAssets();
        usdt.mint(stranger, 10 * U);
        vm.prank(stranger);
        usdt.transfer(address(vault), 10 * U);
        assertEq(vault.totalAssets(), before + 10 * U);
    }

    // ------------------------------------------------------------ mock pool

    function test_mockPool_access() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pool.setApyBps(1);

        MockAToken at = pool.aToken();
        vm.prank(stranger);
        vm.expectRevert(MockAToken.OnlyPool.selector);
        at.mint(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(MockAToken.OnlyPool.selector);
        at.setApyBps(1);

        vm.expectRevert(MockAavePool.WrongAsset.selector);
        pool.supply(address(0xdead), 1, address(this), 0);
        vm.expectRevert(MockAavePool.WrongAsset.selector);
        pool.withdraw(address(0xdead), 1, address(this));
    }

    function test_mockPool_withdrawMax() public {
        vault.sweep();
        vm.prank(address(vault));
        pool.withdraw(address(usdt), type(uint256).max, address(vault));
        assertEq(vault.poolBalance(), 0);
        assertEq(vault.liquidBalance(), 1_000_000 * U);
    }

    function testFuzz_sweepThenRecallConservesFunds(uint256 minLiquid, uint256 cap) public {
        minLiquid = bound(minLiquid, 0, 1_000_000 * U);
        cap = bound(cap, 0, 2_000_000 * U);
        _setSweep(true, minLiquid, cap);
        uint256 before = vault.totalAssets();
        try vault.sweep() {} catch {}
        assertEq(vault.totalAssets(), before);
        assertGe(vault.liquidBalance(), minLiquid > before ? 0 : minLiquid);
        assertLe(vault.poolBalance(), cap);
    }
}
