// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Approval, Payment, ScheduleCreateData, VestingCreateData} from "../../src/OrgTypes.sol";

/// @dev Independent EIP-712 hashing for tests. Type strings are written out literally here (not imported)
///      so a typo in the contracts' type hashes is caught.
abstract contract Sig is Test {
    function _domain(address vault) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BetterCallOps"),
                keccak256("1"),
                block.chainid,
                vault
            )
        );
    }

    function _digest(address vault, bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domain(vault), structHash));
    }

    /// @dev `pks` must already be sorted by address; the first `n` sign.
    function _sign(address vault, bytes32 structHash, uint256[] memory pks, uint256 n)
        internal
        view
        returns (Approval[] memory a)
    {
        a = new Approval[](n);
        bytes32 d = _digest(vault, structHash);
        for (uint256 i; i < n; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], d);
            a[i] = Approval(vm.addr(pks[i]), abi.encodePacked(r, s, v));
        }
    }

    function _hPayment(Payment memory p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Payment(uint8 kind,address payee,uint256 amount,bytes32 budgetId,bytes32 ref,uint256 nonce,uint64 validBefore)"
                ),
                p.kind,
                p.payee,
                p.amount,
                p.budgetId,
                p.ref,
                p.nonce,
                p.validBefore
            )
        );
    }

    function _hSchedule(ScheduleCreateData memory s) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "ScheduleCreate(address payee,uint256 amount,uint64 start,uint64 end,uint8 unit,uint16 every,bytes32 budgetId,bytes32 ref,uint256 nonce,uint64 validBefore)"
                ),
                s.payee,
                s.amount,
                s.start,
                s.end,
                uint8(s.unit),
                s.every,
                s.budgetId,
                s.ref,
                s.nonce,
                s.validBefore
            )
        );
    }

    function _hRun(uint256 id, uint256 run, uint64 validBefore) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(keccak256("ScheduledRun(uint256 scheduleId,uint256 run,uint64 validBefore)"), id, run, validBefore)
        );
    }

    function _hCancel(uint256 id, uint256 nonce, uint64 validBefore) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("ScheduleCancel(uint256 scheduleId,uint256 nonce,uint64 validBefore)"), id, nonce, validBefore
            )
        );
    }

    function _hVesting(VestingCreateData memory v) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "VestingCreate(address beneficiary,uint256 total,uint64 start,uint16 cliffMonths,uint16 durationMonths,uint16 stepMonths,bool revocable,bytes32 budgetId,bytes32 ref,uint256 nonce,uint64 validBefore)"
                ),
                v.beneficiary,
                v.total,
                v.start,
                v.cliffMonths,
                v.durationMonths,
                v.stepMonths,
                v.revocable,
                v.budgetId,
                v.ref,
                v.nonce,
                v.validBefore
            )
        );
    }

    function _hRecall(uint256 amount, uint256 nonce, uint64 validBefore) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(keccak256("Recall(uint256 amount,uint256 nonce,uint64 validBefore)"), amount, nonce, validBefore)
        );
    }

    function _hInvalidate(uint256 target, uint256 nonce, uint64 validBefore) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("InvalidateNonce(uint256 target,uint256 nonce,uint64 validBefore)"), target, nonce, validBefore
            )
        );
    }

    function _hGov(uint8 action, bytes memory data, uint256 nonce, uint64 validBefore) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("Governance(uint8 action,bytes data,uint256 nonce,uint64 validBefore)"),
                action,
                keccak256(data),
                nonce,
                validBefore
            )
        );
    }
}
