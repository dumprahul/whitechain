// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SchedulesModule} from "./SchedulesModule.sol";
import {DateTime} from "../libs/DateTime.sol";
import {Approval, Vesting, VestingCreateData} from "../OrgTypes.sol";

/// @notice Month-based employee vesting. Funds are reserved at creation; releases are permissionless.
abstract contract VestingModule is SchedulesModule {
    using SafeERC20 for *;

    uint16 public constant MAX_VESTING_MONTHS = 120;

    mapping(uint256 => Vesting) internal _vestings;
    uint256 public vestingCount;

    event VestingCreated(
        uint256 indexed id, address indexed beneficiary, uint256 total, uint64 start, uint16 cliffMonths, uint16 durationMonths, uint16 stepMonths, bool revocable, bytes32 ref
    );
    event VestingReleased(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event VestingRevoked(uint256 indexed id, uint64 effectiveAt, uint256 unvestedReturned);
    event BeneficiaryChanged(uint256 indexed id, address indexed oldBeneficiary, address indexed newBeneficiary);

    error InvalidVestingParams();
    error VestingNotFound(uint256 id);
    error NotRevocable(uint256 id);
    error AlreadyRevoked(uint256 id);
    error NothingToRelease(uint256 id);
    error InvalidRevokeTime();

    function getVesting(uint256 id) external view returns (Vesting memory) {
        if (id >= vestingCount) revert VestingNotFound(id);
        return _vestings[id];
    }

    /// @notice Amount vested at the current time (capped at the revoke time when revoked, never below released).
    function vestedAmount(uint256 id) public view returns (uint256) {
        if (id >= vestingCount) revert VestingNotFound(id);
        return _vestedAt(_vestings[id], block.timestamp);
    }

    /// @notice Vested but not yet released.
    function releasable(uint256 id) public view returns (uint256) {
        return vestedAmount(id) - _vestings[id].released;
    }

    function createVesting(VestingCreateData calldata v, Approval[] calldata approvals)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (!isPayee[v.beneficiary]) revert PayeeNotRegistered(v.beneficiary);
        if (
            v.total == 0 || v.total > type(uint128).max || v.start == 0 || v.durationMonths == 0
                || v.durationMonths > MAX_VESTING_MONTHS || v.cliffMonths > v.durationMonths
                || (v.stepMonths != 0 && v.durationMonths % v.stepMonths != 0)
        ) revert InvalidVestingParams();
        _authorize(
            keccak256(abi.encode(VESTING_CREATE_TYPEHASH, v)),
            approvalsRequired(v.total),
            v.validBefore,
            v.nonce,
            true,
            approvals
        );
        _spendBudget(v.budgetId, v.total);
        uint256 available = availableToSpend();
        if (v.total > available) revert InsufficientAvailable(v.total, available);
        reservedVesting += v.total;

        id = vestingCount++;
        _vestings[id] = Vesting({
            beneficiary: v.beneficiary,
            total: uint128(v.total),
            released: 0,
            start: v.start,
            cliffMonths: v.cliffMonths,
            durationMonths: v.durationMonths,
            stepMonths: v.stepMonths,
            revocable: v.revocable,
            revoked: false,
            revokedAt: 0,
            ref: v.ref
        });
        emit VestingCreated(
            id, v.beneficiary, v.total, v.start, v.cliffMonths, v.durationMonths, v.stepMonths, v.revocable, v.ref
        );
    }

    /// @notice Pay the beneficiary what has vested and not yet been released. Anyone can call; funds only go
    ///         to the beneficiary.
    function release(uint256 id) external nonReentrant {
        uint256 amount = releasable(id);
        if (amount == 0) revert NothingToRelease(id);
        Vesting storage v = _vestings[id];
        v.released += uint128(amount);
        reservedVesting -= amount;
        _ensureLiquid(amount);
        usdt.safeTransfer(v.beneficiary, amount);
        emit VestingReleased(id, v.beneficiary, amount);
    }

    // ------------------------------------------------------------ internals

    function _vestedAt(Vesting storage v, uint256 ts) internal view returns (uint256 vested) {
        uint256 t = ts;
        if (v.revoked && v.revokedAt < t) t = v.revokedAt;
        uint256 total = v.total;
        uint256 end = DateTime.addMonths(v.start, v.durationMonths);
        uint256 cliffAt = DateTime.addMonths(v.start, v.cliffMonths);
        if (t < cliffAt) {
            vested = 0;
        } else if (t >= end) {
            vested = total;
        } else if (v.stepMonths == 0) {
            vested = (total * (t - v.start)) / (end - v.start);
        } else {
            uint256 steps = DateTime.diffMonths(v.start, t) / v.stepMonths;
            uint256 months = steps * v.stepMonths;
            if (months > v.durationMonths) months = v.durationMonths;
            vested = (total * months) / v.durationMonths;
        }
        if (vested < v.released) vested = v.released;
    }

    /// @dev Stops vesting at `effectiveAt`; the unvested part becomes spendable again.
    function _revokeVesting(uint256 id, uint64 effectiveAt) internal {
        if (id >= vestingCount) revert VestingNotFound(id);
        Vesting storage v = _vestings[id];
        if (!v.revocable) revert NotRevocable(id);
        if (v.revoked) revert AlreadyRevoked(id);
        if (effectiveAt > block.timestamp) revert InvalidRevokeTime();
        v.revoked = true;
        v.revokedAt = effectiveAt;
        uint256 unvested = v.total - _vestedAt(v, block.timestamp);
        reservedVesting -= unvested;
        emit VestingRevoked(id, effectiveAt, unvested);
    }

    function _changeBeneficiary(uint256 id, address newBeneficiary) internal {
        if (id >= vestingCount) revert VestingNotFound(id);
        if (!isPayee[newBeneficiary]) revert PayeeNotRegistered(newBeneficiary);
        Vesting storage v = _vestings[id];
        emit BeneficiaryChanged(id, v.beneficiary, newBeneficiary);
        v.beneficiary = newBeneficiary;
    }
}
