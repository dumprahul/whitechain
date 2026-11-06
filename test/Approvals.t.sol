// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BaseTest} from "./utils/Base.t.sol";
import {OrgVault} from "../src/OrgVault.sol";
import {ApprovalsModule} from "../src/modules/ApprovalsModule.sol";
import {Approval, OrgInit, Payment} from "../src/OrgTypes.sol";

/// @dev Minimal ERC-1271 wallet controlled by one EOA key.
contract Wallet1271 {
    address public immutable signerKey;

    constructor(address signerKey_) {
        signerKey = signerKey_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address r,,) = ECDSA.tryRecover(hash, sig);
        return r == signerKey ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract ApprovalsTest is BaseTest {
    // ----------------------------------------------------------------- tiers

    function test_tierBoundaries() public view {
        assertEq(vault.approvalsRequired(0), 1);
        assertEq(vault.approvalsRequired(1), 1);
        assertEq(vault.approvalsRequired(999_990_000), 1); // 999.99
        assertEq(vault.approvalsRequired(1_000_000_000), 3); // 1,000.00
        assertEq(vault.approvalsRequired(5_000_000_000), 3); // 5,000.00 exactly is the middle tier
        assertEq(vault.approvalsRequired(5_000_010_000), 5); // 5,000.01
        assertEq(vault.approvalsRequired(type(uint256).max), 5);
    }

    function test_tiers_clampedToApproverCount() public {
        _makeApprovers(3);
        OrgVault v3 = _createOrg(_defaultInit(), bytes32(uint256(7)));
        assertEq(v3.approvalsRequired(100 * U), 1);
        assertEq(v3.approvalsRequired(2_000 * U), 3);
        assertEq(v3.approvalsRequired(50_000 * U), 3); // 5 clamped to 3, not stuck

        _makeApprovers(1);
        OrgVault v1 = _createOrg(_defaultInit(), bytes32(uint256(8)));
        assertEq(v1.approvalsRequired(50_000 * U), 1);
    }

    function test_paymentNeedsTierApprovals_boundaries() public {
        // 999.99 -> 1, 1000 -> 3, 5000 -> 3, 5000.01 -> 5
        uint256[4] memory amounts = [uint256(999_990_000), 1_000 * U, 5_000 * U, 5_000_010_000];
        uint256[4] memory need = [uint256(1), 3, 3, 5];
        for (uint256 i; i < 4; ++i) {
            Payment memory p = _newPayment(vendor, amounts[i]);
            vm.expectRevert(
                abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, need[i] - 1, need[i])
            );
            vault.executePayment(p, _signedPayment(p, need[i] - 1));
            vault.executePayment(p, _signedPayment(p, need[i]));
        }
        assertEq(usdt.balanceOf(vendor), 999_990_000 + 1_000 * U + 5_000 * U + 5_000_010_000);
    }

    function testFuzz_approvalsRequired_monotonicAndBounded(uint256 a, uint256 b) public view {
        (uint256 lo, uint256 hi) = a <= b ? (a, b) : (b, a);
        uint256 rLo = vault.approvalsRequired(lo);
        uint256 rHi = vault.approvalsRequired(hi);
        assertLe(rLo, rHi);
        assertGe(rLo, 1);
        assertLe(rHi, vault.approverCount());
    }

    // ------------------------------------------------------ signature rules

    function test_duplicateSignerReverts() public {
        Payment memory p = _newPayment(vendor, 2_000 * U);
        Approval[] memory a = _signedPayment(p, 2);
        Approval[] memory dup = new Approval[](3);
        dup[0] = a[0];
        dup[1] = a[1];
        dup[2] = a[1];
        vm.expectRevert(ApprovalsModule.BadSignatureOrder.selector);
        vault.executePayment(p, dup);
    }

    function test_unsortedSignersRevert() public {
        Payment memory p = _newPayment(vendor, 2_000 * U);
        Approval[] memory a = _signedPayment(p, 3);
        (a[0], a[1]) = (a[1], a[0]);
        vm.expectRevert(ApprovalsModule.BadSignatureOrder.selector);
        vault.executePayment(p, a);
    }

    function test_nonApproverReverts() public {
        Payment memory p = _newPayment(vendor, 100 * U);
        uint256 pk = 0xBAD;
        bytes32 d = _digest(address(vault), _hPayment(p));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        Approval[] memory a = new Approval[](1);
        a[0] = Approval(vm.addr(pk), abi.encodePacked(r, s, v));
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.NotApprover.selector, vm.addr(pk)));
        vault.executePayment(p, a);
    }

    function test_signatureFromWrongKeyReverts() public {
        Payment memory p = _newPayment(vendor, 100 * U);
        Approval[] memory a = _signedPayment(p, 1);
        // valid signature, but claimed under a different approver's address
        a[0].signer = approvers[approvers.length - 1] == a[0].signer ? approvers[0] : approvers[approvers.length - 1];
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InvalidSignature.selector, a[0].signer));
        vault.executePayment(p, a);
    }

    function test_garbageSignatureReverts() public {
        Payment memory p = _newPayment(vendor, 100 * U);
        Approval[] memory a = new Approval[](1);
        a[0] = Approval(approvers[0], hex"1234");
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InvalidSignature.selector, approvers[0]));
        vault.executePayment(p, a);
    }

    function test_tamperedPaymentReverts() public {
        Payment memory p = _newPayment(vendor, 100 * U);
        Approval[] memory a = _signedPayment(p, 1);
        p.amount = 200 * U; // changed after signing
        vm.expectRevert();
        vault.executePayment(p, a);
        p.amount = 100 * U;
        p.payee = employee; // payee swapped
        vm.expectRevert();
        vault.executePayment(p, a);
    }

    function test_expiredReverts() public {
        Payment memory p = _newPayment(vendor, 100 * U);
        Approval[] memory a = _signedPayment(p, 1);
        vm.warp(p.validBefore + 1);
        vm.expectRevert(ApprovalsModule.Expired.selector);
        vault.executePayment(p, a);
        // exactly at validBefore is still valid
        vm.warp(p.validBefore);
        vault.executePayment(p, a);
    }

    function test_nonceReuseReverts() public {
        Payment memory p = _newPayment(vendor, 100 * U);
        Approval[] memory a = _signedPayment(p, 1);
        vault.executePayment(p, a);
        vm.expectRevert(ApprovalsModule.NonceUsed.selector);
        vault.executePayment(p, a);
        assertTrue(vault.nonceUsed(p.nonce));
    }

    function test_extraSignaturesAllowedButAllMustBeValid() public {
        Payment memory p = _newPayment(vendor, 100 * U); // needs 1
        vault.executePayment(p, _signedPayment(p, 5));
        Payment memory p2 = _newPayment(vendor, 100 * U);
        Approval[] memory a = _signedPayment(p2, 2);
        a[1].signature = hex"00";
        vm.expectRevert();
        vault.executePayment(p2, a);
    }

    function test_noApprovalsReverts() public {
        Payment memory p = _newPayment(vendor, 1 * U);
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InsufficientApprovals.selector, 0, 1));
        vault.executePayment(p, new Approval[](0));
    }

    // ------------------------------------------------------ invalidateNonce

    function test_invalidateNonce_blocksPendingRequest() public {
        Payment memory p = _newPayment(vendor, 100 * U);
        Approval[] memory collected = _signedPayment(p, 1);

        uint256 n2 = _nonce();
        uint64 vb = _vb();
        vault.invalidateNonce(p.nonce, n2, vb, _approvalsFor(vault, _hInvalidate(p.nonce, n2, vb), 1));
        assertTrue(vault.nonceUsed(p.nonce));

        vm.expectRevert(ApprovalsModule.NonceUsed.selector);
        vault.executePayment(p, collected);
    }

    function test_invalidateNonce_needsApproverAndFreshNonce() public {
        uint256 n2 = _nonce();
        uint64 vb = _vb();
        vm.expectRevert();
        vault.invalidateNonce(5, n2, vb, new Approval[](0));
        vault.invalidateNonce(5, n2, vb, _approvalsFor(vault, _hInvalidate(5, n2, vb), 1));
        vm.expectRevert(ApprovalsModule.NonceUsed.selector); // same invalidation cannot be replayed
        vault.invalidateNonce(5, n2, vb, _approvalsFor(vault, _hInvalidate(5, n2, vb), 1));
    }

    // -------------------------------------------------------------- ERC-1271

    function test_erc1271ContractWalletApprover() public {
        uint256 ownerPk = 0x1271;
        Wallet1271 wallet = new Wallet1271(vm.addr(ownerPk));
        OrgInit memory init = _defaultInit();
        init.approvers = new address[](1);
        init.approvers[0] = address(wallet);
        OrgVault v = _createOrg(init, bytes32(uint256(77)));
        usdt.mint(address(v), 10_000 * U);

        Payment memory p = Payment(0, vendor, 500 * U, GENERAL, bytes32(0), _nonce(), _vb());
        bytes32 d = _digest(address(v), _hPayment(p));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(ownerPk, d);
        Approval[] memory a = new Approval[](1);
        a[0] = Approval(address(wallet), abi.encodePacked(r, s, vv));
        v.executePayment(p, a);
        assertEq(usdt.balanceOf(vendor), 500 * U);

        // wrong owner key is rejected by the wallet
        Payment memory p2 = Payment(0, vendor, 500 * U, GENERAL, bytes32(0), _nonce(), _vb());
        (vv, r, s) = vm.sign(0xBAD, _digest(address(v), _hPayment(p2)));
        a[0] = Approval(address(wallet), abi.encodePacked(r, s, vv));
        vm.expectRevert(abi.encodeWithSelector(ApprovalsModule.InvalidSignature.selector, address(wallet)));
        v.executePayment(p2, a);
    }
}
