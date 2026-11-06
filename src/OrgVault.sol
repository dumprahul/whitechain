// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {VestingModule} from "./modules/VestingModule.sol";
import {YieldModule} from "./modules/YieldModule.sol";
import {
    Approval, BudgetInit, GovAction, OrgInit, SweepConfig, Tier
} from "./OrgTypes.sol";

/// @title OrgVault
/// @notice Per-business finance vault: payments, budgets, schedules, vesting and yield, all gated by
///         on-chain approver signatures. Deployed once as an implementation and cloned (EIP-1167) per business.
/// @dev Not upgradeable. The EIP-712 domain uses each clone's own address, so signatures cannot be replayed
///      across vaults. Constructor arguments are immutables, which clones read from the implementation code.
contract OrgVault is VestingModule {
    /// @notice The factory that creates clones of this implementation; only it can initialize them.
    address public immutable factory;

    bool public initialized;
    bytes32 public metadataHash;

    event Initialized(bytes32 metadataHash);

    error OnlyFactory();
    error AlreadyInitialized();
    error InvalidGovAction();

    constructor(address factory_, address usdt_, address aavePool_, address aToken_, uint256 minSweepAmount_)
        YieldModule(usdt_, aavePool_, aToken_, minSweepAmount_)
    {
        factory = factory_;
    }

    /// @notice One-time setup, called by the factory in the same transaction that clones the vault.
    function initialize(OrgInit calldata init) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        uint256 n = init.approvers.length;
        if (n == 0) revert InvalidApprovers();
        for (uint256 i; i < n; ++i) {
            _addApprover(init.approvers[i]);
        }
        _setTiers(init.tiers);
        _setGovernanceParams(init.payeeApprovals, init.governanceApprovals);

        for (uint256 i; i < init.budgets.length; ++i) {
            BudgetInit calldata b = init.budgets[i];
            _setBudget(b.id, b.limit, b.periodMonths);
        }
        if (!_budgets[GENERAL].exists) revert BudgetMissing(GENERAL);

        _setSweepConfig(init.sweep);
        for (uint256 i; i < init.payees.length; ++i) {
            _setPayee(init.payees[i], true);
        }
        metadataHash = init.metadataHash;
        emit Initialized(init.metadataHash);
    }

    /// @notice Cancel a pending request: marks `target` as used so collected signatures can never be submitted.
    ///         One approval.
    function invalidateNonce(uint256 target, uint256 nonce, uint64 validBefore, Approval[] calldata approvals)
        external
    {
        _authorize(
            keccak256(abi.encode(INVALIDATE_NONCE_TYPEHASH, target, nonce, validBefore)),
            _clamp(1),
            validBefore,
            nonce,
            true,
            approvals
        );
        nonceUsed[target] = true;
        emit NonceInvalidated(target);
    }

    /// @notice Change the vault's rules. Payee changes need `payeeApprovals`, everything else
    ///         `governanceApprovals` (both clamped to the approver count). Data encodings: see `GovAction`.
    function executeGovernance(
        uint8 action,
        bytes calldata data,
        uint256 nonce,
        uint64 validBefore,
        Approval[] calldata approvals
    ) external nonReentrant {
        if (action > uint8(GovAction.RemovePayee)) revert InvalidGovAction();
        GovAction a = GovAction(action);
        bool payeeAction = a == GovAction.AddPayee || a == GovAction.RemovePayee;
        _authorize(
            keccak256(abi.encode(GOVERNANCE_TYPEHASH, action, keccak256(data), nonce, validBefore)),
            _clamp(payeeAction ? payeeApprovals : governanceApprovals),
            validBefore,
            nonce,
            true,
            approvals
        );

        if (a == GovAction.AddApprover) {
            _addApprover(abi.decode(data, (address)));
        } else if (a == GovAction.RemoveApprover) {
            _removeApprover(abi.decode(data, (address)));
        } else if (a == GovAction.SetTiers) {
            _setTiers(abi.decode(data, (Tier[])));
        } else if (a == GovAction.SetBudget) {
            (bytes32 id, uint128 limit, uint16 period) = abi.decode(data, (bytes32, uint128, uint16));
            _setBudget(id, limit, period);
        } else if (a == GovAction.SetSweepConfig) {
            _setSweepConfig(abi.decode(data, (SweepConfig)));
        } else if (a == GovAction.RevokeVesting) {
            (uint256 id, uint64 effectiveAt) = abi.decode(data, (uint256, uint64));
            _revokeVesting(id, effectiveAt);
        } else if (a == GovAction.ChangeBeneficiary) {
            (uint256 id, address newBeneficiary) = abi.decode(data, (uint256, address));
            _changeBeneficiary(id, newBeneficiary);
        } else if (a == GovAction.SetGovernanceParams) {
            (uint8 payee, uint8 governance) = abi.decode(data, (uint8, uint8));
            _setGovernanceParams(payee, governance);
        } else if (a == GovAction.AddPayee) {
            _setPayee(abi.decode(data, (address)), true);
        } else {
            _setPayee(abi.decode(data, (address)), false);
        }
    }
}
