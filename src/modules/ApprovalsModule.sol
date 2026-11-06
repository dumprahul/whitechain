// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Tier, Approval} from "../OrgTypes.sol";

/// @notice Approver registry, approval tiers, nonces and EIP-712 signature verification.
/// @dev Every spend or rule change in the vault is authorized through `_authorize`.
abstract contract ApprovalsModule is EIP712 {
    uint256 public constant MAX_APPROVERS = 50;
    uint256 public constant MAX_TIERS = 10;

    bytes32 internal constant PAYMENT_TYPEHASH = keccak256(
        "Payment(uint8 kind,address payee,uint256 amount,bytes32 budgetId,bytes32 ref,uint256 nonce,uint64 validBefore)"
    );
    bytes32 internal constant SCHEDULE_CREATE_TYPEHASH = keccak256(
        "ScheduleCreate(address payee,uint256 amount,uint64 start,uint64 end,uint8 unit,uint16 every,bytes32 budgetId,bytes32 ref,uint256 nonce,uint64 validBefore)"
    );
    bytes32 internal constant SCHEDULED_RUN_TYPEHASH =
        keccak256("ScheduledRun(uint256 scheduleId,uint256 run,uint64 validBefore)");
    bytes32 internal constant SCHEDULE_CANCEL_TYPEHASH =
        keccak256("ScheduleCancel(uint256 scheduleId,uint256 nonce,uint64 validBefore)");
    bytes32 internal constant VESTING_CREATE_TYPEHASH = keccak256(
        "VestingCreate(address beneficiary,uint256 total,uint64 start,uint16 cliffMonths,uint16 durationMonths,uint16 stepMonths,bool revocable,bytes32 budgetId,bytes32 ref,uint256 nonce,uint64 validBefore)"
    );
    bytes32 internal constant RECALL_TYPEHASH = keccak256("Recall(uint256 amount,uint256 nonce,uint64 validBefore)");
    bytes32 internal constant INVALIDATE_NONCE_TYPEHASH =
        keccak256("InvalidateNonce(uint256 target,uint256 nonce,uint64 validBefore)");
    bytes32 internal constant GOVERNANCE_TYPEHASH =
        keccak256("Governance(uint8 action,bytes data,uint256 nonce,uint64 validBefore)");

    Tier[] internal _tiers;
    address[] internal _approvers;
    mapping(address => bool) public isApprover;
    mapping(uint256 => bool) public nonceUsed;

    /// @notice Approvals needed to add or remove a payee (clamped to the approver count).
    uint8 public payeeApprovals;
    /// @notice Approvals needed for rule changes (clamped to the approver count).
    uint8 public governanceApprovals;

    event TiersSet(Tier[] tiers);
    event ApproverAdded(address indexed approver);
    event ApproverRemoved(address indexed approver);
    event GovernanceParamsSet(uint8 payeeApprovals, uint8 governanceApprovals);
    event NonceInvalidated(uint256 indexed nonce);

    error NotApprover(address signer);
    error BadSignatureOrder();
    error InvalidSignature(address signer);
    error InsufficientApprovals(uint256 provided, uint256 required);
    error Expired();
    error NonceUsed();
    error InvalidTiers();
    error InvalidApprovers();
    error InvalidGovernanceParams();
    error LastApprover();

    constructor() EIP712("BetterCallOps", "1") {}

    // ---------------------------------------------------------------- views

    /// @notice The EIP-712 domain separator of this vault (chain id + this vault's address).
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function approverCount() public view returns (uint256) {
        return _approvers.length;
    }

    function getApprovers() external view returns (address[] memory) {
        return _approvers;
    }

    function getTiers() external view returns (Tier[] memory) {
        return _tiers;
    }

    /// @notice Approvals needed for an amount: first tier with amount <= maxAmount, clamped to approver count.
    function approvalsRequired(uint256 amount) public view returns (uint256) {
        uint256 n = _tiers.length;
        uint256 count = _tiers[n - 1].approvals;
        for (uint256 i; i < n; ++i) {
            if (amount <= _tiers[i].maxAmount) {
                count = _tiers[i].approvals;
                break;
            }
        }
        return _clamp(count);
    }

    // ------------------------------------------------------------- internals

    function _clamp(uint256 count) internal view returns (uint256) {
        uint256 n = _approvers.length;
        return count > n ? n : count;
    }

    /// @dev Checks expiry, burns the nonce (when `useNonce`), and verifies `required` approver signatures.
    function _authorize(
        bytes32 structHash,
        uint256 required,
        uint64 validBefore,
        uint256 nonce,
        bool useNonce,
        Approval[] calldata approvals
    ) internal {
        if (block.timestamp > validBefore) revert Expired();
        if (useNonce) {
            if (nonceUsed[nonce]) revert NonceUsed();
            nonceUsed[nonce] = true;
        }
        _verifyApprovals(structHash, required, approvals);
    }

    function _verifyApprovals(bytes32 structHash, uint256 required, Approval[] calldata approvals) internal view {
        uint256 len = approvals.length;
        if (len < required) revert InsufficientApprovals(len, required);
        bytes32 digest = _hashTypedDataV4(structHash);
        address last;
        for (uint256 i; i < len; ++i) {
            address signer = approvals[i].signer;
            if (signer <= last) revert BadSignatureOrder();
            last = signer;
            if (!isApprover[signer]) revert NotApprover(signer);
            if (!SignatureChecker.isValidSignatureNow(signer, digest, approvals[i].signature)) {
                revert InvalidSignature(signer);
            }
        }
    }

    function _setTiers(Tier[] memory tiers) internal {
        uint256 n = tiers.length;
        if (n == 0 || n > MAX_TIERS) revert InvalidTiers();
        for (uint256 i; i < n; ++i) {
            if (tiers[i].approvals == 0) revert InvalidTiers();
            if (i > 0 && tiers[i].maxAmount <= tiers[i - 1].maxAmount) revert InvalidTiers();
        }
        if (tiers[n - 1].maxAmount != type(uint128).max) revert InvalidTiers();
        delete _tiers;
        for (uint256 i; i < n; ++i) {
            _tiers.push(tiers[i]);
        }
        emit TiersSet(tiers);
    }

    function _addApprover(address approver) internal {
        if (approver == address(0) || isApprover[approver] || _approvers.length >= MAX_APPROVERS) {
            revert InvalidApprovers();
        }
        isApprover[approver] = true;
        _approvers.push(approver);
        emit ApproverAdded(approver);
    }

    function _removeApprover(address approver) internal {
        if (!isApprover[approver]) revert InvalidApprovers();
        if (_approvers.length == 1) revert LastApprover();
        isApprover[approver] = false;
        uint256 n = _approvers.length;
        for (uint256 i; i < n; ++i) {
            if (_approvers[i] == approver) {
                _approvers[i] = _approvers[n - 1];
                _approvers.pop();
                break;
            }
        }
        emit ApproverRemoved(approver);
    }

    function _setGovernanceParams(uint8 payee, uint8 governance) internal {
        if (payee == 0 || governance == 0) revert InvalidGovernanceParams();
        payeeApprovals = payee;
        governanceApprovals = governance;
        emit GovernanceParamsSet(payee, governance);
    }
}
