// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";
import {OrgInit} from "./OrgTypes.sol";

interface IOrgVaultImplementation {
    function factory() external view returns (address);
    function initialize(OrgInit calldata init) external;
}

/// @title OrgFactory
/// @notice Charges the onboarding fee, deploys one OrgVault clone per business, and keeps the registry
///         (`isOrg`) that the relayer checks. The owner (the platform) can change the fee and the
///         implementation for NEW businesses only; it has no way to touch an existing vault.
contract OrgFactory is Ownable {
    using SafeERC20 for IERC20;

    /// @dev EIP-3009 signature plus validity window.
    struct Auth {
        uint64 validAfter;
        uint64 validBefore;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    IERC20 public immutable usdt;

    address public implementation;
    uint256 public onboardingFee;
    address public feeRecipient;
    bool public creationPaused;

    mapping(address => bool) public isOrg;
    address[] internal _orgs;

    event OrgCreated(address indexed org, address indexed payer, bytes32 salt, bytes32 metadataHash);
    event OnboardingFeeSet(uint256 fee);
    event FeeRecipientSet(address recipient);
    event ImplementationSet(address implementation);
    event CreationPausedSet(bool paused);

    error CreationIsPaused();
    error NoImplementation();
    error ZeroAddress();
    error WrongFactory();

    constructor(address usdt_, uint256 onboardingFee_, address feeRecipient_, address owner_) Ownable(owner_) {
        if (usdt_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        usdt = IERC20(usdt_);
        onboardingFee = onboardingFee_;
        feeRecipient = feeRecipient_;
    }

    // ---------------------------------------------------------------- views

    function orgCount() external view returns (uint256) {
        return _orgs.length;
    }

    function getOrgs(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = _orgs.length;
        if (offset >= n) return page;
        uint256 end = offset + limit > n ? n : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _orgs[i];
        }
    }

    /// @notice The EIP-3009 nonce the payer must sign: bound to chain, factory, payer, salt and the full init.
    function authorizationNonce(address payer, OrgInit calldata init, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), payer, salt, keccak256(abi.encode(init))));
    }

    /// @notice Address the vault for (`payer`, `salt`) will have, for the current implementation.
    function previewOrgAddress(address payer, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _cloneSalt(payer, salt), address(this));
    }

    // ------------------------------------------------------------- creation

    /// @notice Create a business vault. The payer signed an EIP-3009 authorization for the onboarding fee whose
    ///         nonce commits to `init`, so the relayer cannot swap in different approvers or rules.
    function createOrg(address payer, OrgInit calldata init, bytes32 salt, Auth calldata auth)
        external
        returns (address org)
    {
        if (creationPaused) revert CreationIsPaused();
        address impl = implementation;
        if (impl == address(0)) revert NoImplementation();

        uint256 fee = onboardingFee;
        if (fee != 0) {
            IERC3009(address(usdt)).receiveWithAuthorization(
                payer,
                address(this),
                fee,
                auth.validAfter,
                auth.validBefore,
                authorizationNonce(payer, init, salt),
                auth.v,
                auth.r,
                auth.s
            );
            usdt.safeTransfer(feeRecipient, fee);
        }

        org = Clones.cloneDeterministic(impl, _cloneSalt(payer, salt));
        isOrg[org] = true;
        _orgs.push(org);
        IOrgVaultImplementation(org).initialize(init);
        emit OrgCreated(org, payer, salt, init.metadataHash);
    }

    // ------------------------------------------------------- platform admin

    function setOnboardingFee(uint256 fee) external onlyOwner {
        onboardingFee = fee;
        emit OnboardingFeeSet(fee);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Set the OrgVault implementation used for new businesses (its `factory()` must be this contract).
    function setImplementation(address impl) external onlyOwner {
        if (impl == address(0)) revert ZeroAddress();
        if (IOrgVaultImplementation(impl).factory() != address(this)) revert WrongFactory();
        implementation = impl;
        emit ImplementationSet(impl);
    }

    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPausedSet(paused);
    }

    function _cloneSalt(address payer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(payer, salt));
    }
}
