// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {YieldModule} from "./YieldModule.sol";
import {Approval, Payment} from "../OrgTypes.sol";

/// @notice Payee registry plus invoice payments and reimbursements.
abstract contract PaymentsModule is YieldModule {
    mapping(address => bool) public isPayee;

    event PayeeSet(address indexed payee, bool allowed);
    event PaymentExecuted(
        uint8 kind, address indexed payee, uint256 amount, bytes32 indexed budgetId, bytes32 ref, uint256 nonce
    );

    error PayeeNotRegistered(address payee);
    error InvalidKind();

    /// @notice Pay a registered payee after the tier's worth of approvals. kind: 0 invoice, 1 reimbursement.
    function executePayment(Payment calldata p, Approval[] calldata approvals) external nonReentrant {
        if (p.kind > 1) revert InvalidKind();
        if (p.amount == 0) revert ZeroAmount();
        if (!isPayee[p.payee]) revert PayeeNotRegistered(p.payee);
        _authorize(
            keccak256(abi.encode(PAYMENT_TYPEHASH, p)),
            approvalsRequired(p.amount),
            p.validBefore,
            p.nonce,
            true,
            approvals
        );
        _spendBudget(p.budgetId, p.amount);
        _payFromAvailable(p.payee, p.amount);
        emit PaymentExecuted(p.kind, p.payee, p.amount, p.budgetId, p.ref, p.nonce);
    }

    function _setPayee(address payee, bool allowed) internal {
        if (payee == address(0)) revert PayeeNotRegistered(payee);
        isPayee[payee] = allowed;
        emit PayeeSet(payee, allowed);
    }
}
