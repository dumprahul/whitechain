// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Shared structs and enums for the BetterCallOps vault and factory.

/// @dev Approval tier. Tiers are ascending by maxAmount; the last one must be type(uint128).max.
struct Tier {
    uint128 maxAmount;
    uint8 approvals;
}

/// @dev One approver signature. The list passed to the vault must be strictly increasing by signer.
struct Approval {
    address signer;
    bytes signature;
}

/// @dev EIP-712 `Payment`. kind: 0 = invoice, 1 = reimbursement. Field order matches the type string.
struct Payment {
    uint8 kind;
    address payee;
    uint256 amount;
    bytes32 budgetId;
    bytes32 ref;
    uint256 nonce;
    uint64 validBefore;
}

enum Unit {
    DAY,
    WEEK,
    MONTH
}

/// @dev EIP-712 `ScheduleCreate`.
struct ScheduleCreateData {
    address payee;
    uint256 amount;
    uint64 start;
    uint64 end; // 0 = open-ended
    Unit unit;
    uint16 every;
    bytes32 budgetId;
    bytes32 ref;
    uint256 nonce;
    uint64 validBefore;
}

/// @dev EIP-712 `VestingCreate`.
struct VestingCreateData {
    address beneficiary;
    uint256 total;
    uint64 start;
    uint16 cliffMonths;
    uint16 durationMonths;
    uint16 stepMonths;
    bool revocable;
    bytes32 budgetId;
    bytes32 ref;
    uint256 nonce;
    uint64 validBefore;
}

struct Budget {
    uint128 limit;
    uint16 periodMonths; // 0 = never resets, 1 = monthly, 3 = quarterly, 12 = yearly
    uint64 anchor; // first day of the month the budget was created (periodic budgets)
    uint64 windowStart; // start of the window `spent` refers to
    uint128 spent;
    bool exists;
}

struct BudgetInit {
    bytes32 id;
    uint128 limit;
    uint16 periodMonths;
}

struct SweepConfig {
    bool enabled;
    uint128 minLiquid; // buffer always kept liquid in the vault
    uint128 maxInYield; // cap on the pool balance
}

struct Schedule {
    address payee;
    uint128 amount;
    uint64 start;
    uint64 end;
    Unit unit;
    uint16 every;
    bytes32 budgetId;
    bytes32 ref;
    bool active;
}

struct Vesting {
    address beneficiary;
    uint128 total;
    uint128 released;
    uint64 start;
    uint16 cliffMonths;
    uint16 durationMonths;
    uint16 stepMonths;
    bool revocable;
    bool revoked;
    uint64 revokedAt;
    bytes32 ref;
}

/// @dev Everything a business chooses when it is created.
struct OrgInit {
    address[] approvers;
    Tier[] tiers;
    uint8 payeeApprovals;
    uint8 governanceApprovals;
    BudgetInit[] budgets; // must contain GENERAL
    SweepConfig sweep;
    address[] payees; // initial payee registry (bootstrap; later changes need approvals)
    bytes32 metadataHash;
}

/// @dev Governance actions for `executeGovernance`.
enum GovAction {
    AddApprover, // data = abi.encode(address)
    RemoveApprover, // data = abi.encode(address)
    SetTiers, // data = abi.encode(Tier[])
    SetBudget, // data = abi.encode(bytes32 id, uint128 limit, uint16 periodMonths)
    SetSweepConfig, // data = abi.encode(SweepConfig)
    RevokeVesting, // data = abi.encode(uint256 id, uint64 effectiveAt)
    ChangeBeneficiary, // data = abi.encode(uint256 id, address newBeneficiary)
    SetGovernanceParams, // data = abi.encode(uint8 payeeApprovals, uint8 governanceApprovals)
    AddPayee, // data = abi.encode(address)
    RemovePayee // data = abi.encode(address)
}
