// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseTest} from "./utils/Base.t.sol";
import {OrgFactory} from "../src/OrgFactory.sol";
import {OrgVault} from "../src/OrgVault.sol";
import {ApprovalsModule} from "../src/modules/ApprovalsModule.sol";
import {BudgetsModule} from "../src/modules/BudgetsModule.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {BudgetInit, OrgInit, Payment, Tier} from "../src/OrgTypes.sol";

contract FactoryTest is BaseTest {
    bytes32 internal constant SALT2 = bytes32(uint256(2));

    function test_createOrg_collectsFeeAndRegisters() public view {
        assertEq(usdt.balanceOf(feeRecipient), 5 * U);
        assertEq(usdt.balanceOf(address(factory)), 0);
        assertEq(usdt.balanceOf(payer), 0);
        assertTrue(factory.isOrg(address(vault)));
        assertEq(factory.orgCount(), 1);
        assertEq(factory.getOrgs(0, 10)[0], address(vault));
        assertTrue(vault.initialized());
        assertEq(vault.approverCount(), 5);
        assertEq(vault.metadataHash(), keccak256("metadata"));
        assertTrue(vault.isPayee(vendor));
        assertEq(vault.payeeApprovals(), 3);
        assertEq(vault.governanceApprovals(), 5);
    }

    function test_createOrg_emitsEvent() public {
        OrgInit memory init = _defaultInit();
        usdt.mint(payer, 5 * U);
        OrgFactory.Auth memory auth = _authFor(payer, init, SALT2, payerPk);
        address predicted = factory.previewOrgAddress(payer, SALT2);
        vm.expectEmit(true, true, false, true);
        emit OrgFactory.OrgCreated(predicted, payer, SALT2, init.metadataHash);
        factory.createOrg(payer, init, SALT2, auth);
    }

    function test_previewOrgAddress_isDeterministic() public {
        address predicted = factory.previewOrgAddress(payer, SALT2);
        assertEq(address(_createOrg(_defaultInit(), SALT2)), predicted);
    }

    function test_createOrg_nonceMatchesIndependentComputation() public view {
        OrgInit memory init = _defaultInit();
        bytes32 expected = keccak256(abi.encode(block.chainid, address(factory), payer, SALT2, keccak256(abi.encode(init))));
        assertEq(factory.authorizationNonce(payer, init, SALT2), expected);
    }

    function test_createOrg_wrongSignerReverts() public {
        OrgInit memory init = _defaultInit();
        usdt.mint(payer, 5 * U);
        OrgFactory.Auth memory auth = _authFor(payer, init, SALT2, 0xDEAD); // signed by someone else
        vm.expectRevert(MockUSDT.AuthInvalidSignature.selector);
        factory.createOrg(payer, init, SALT2, auth);
    }

    function test_createOrg_signatureBoundToParameters() public {
        OrgInit memory init = _defaultInit();
        usdt.mint(payer, 5 * U);
        OrgFactory.Auth memory auth = _authFor(payer, init, SALT2, payerPk);

        // relayer tries to swap an approver for itself
        OrgInit memory evil = _defaultInit();
        evil.approvers[0] = relayer;
        vm.expectRevert(MockUSDT.AuthInvalidSignature.selector);
        factory.createOrg(payer, evil, SALT2, auth);

        // ... or tweaks the metadata
        OrgInit memory evil2 = _defaultInit();
        evil2.metadataHash = bytes32(uint256(1));
        vm.expectRevert(MockUSDT.AuthInvalidSignature.selector);
        factory.createOrg(payer, evil2, SALT2, auth);

        // ... or uses a different salt
        vm.expectRevert(MockUSDT.AuthInvalidSignature.selector);
        factory.createOrg(payer, init, bytes32(uint256(99)), auth);

        // the genuine parameters still work
        factory.createOrg(payer, init, SALT2, auth);
    }

    function test_createOrg_signatureCannotBeReused() public {
        OrgInit memory init = _defaultInit();
        usdt.mint(payer, 10 * U);
        OrgFactory.Auth memory auth = _authFor(payer, init, SALT2, payerPk);
        factory.createOrg(payer, init, SALT2, auth);
        vm.expectRevert();
        factory.createOrg(payer, init, SALT2, auth);
    }

    function test_createOrg_expiredAuthorizationReverts() public {
        OrgInit memory init = _defaultInit();
        usdt.mint(payer, 5 * U);
        OrgFactory.Auth memory auth = _authFor(payer, init, SALT2, payerPk);
        vm.warp(auth.validBefore);
        vm.expectRevert(MockUSDT.AuthExpired.selector);
        factory.createOrg(payer, init, SALT2, auth);
    }

    function test_createOrg_zeroFeeNeedsNoSignature() public {
        vm.prank(platformOwner);
        factory.setOnboardingFee(0);
        OrgFactory.Auth memory empty;
        OrgVault v = OrgVault(factory.createOrg(payer, _defaultInit(), SALT2, empty));
        assertTrue(factory.isOrg(address(v)));
    }

    function test_createOrg_pausedReverts() public {
        vm.prank(platformOwner);
        factory.setCreationPaused(true);
        OrgInit memory init = _defaultInit();
        OrgFactory.Auth memory auth = _authFor(payer, init, SALT2, payerPk);
        vm.expectRevert(OrgFactory.CreationIsPaused.selector);
        factory.createOrg(payer, init, SALT2, auth);
    }

    function test_createOrg_withoutImplementationReverts() public {
        OrgFactory f2 = new OrgFactory(address(usdt), 5 * U, feeRecipient, platformOwner);
        OrgFactory.Auth memory empty;
        vm.expectRevert(OrgFactory.NoImplementation.selector);
        f2.createOrg(payer, _defaultInit(), SALT2, empty);
    }

    function test_cloneHasOwnDomainSeparator() public {
        OrgVault v2 = _createOrg(_defaultInit(), SALT2);
        assertEq(vault.domainSeparator(), _domain(address(vault)));
        assertEq(v2.domainSeparator(), _domain(address(v2)));
        assertTrue(vault.domainSeparator() != v2.domainSeparator());
        assertTrue(vault.domainSeparator() != impl.domainSeparator());
    }

    function test_signatureCannotBeReplayedAcrossVaults() public {
        OrgVault v2 = _createOrg(_defaultInit(), SALT2);
        usdt.mint(address(v2), 10_000 * U);
        Payment memory p = _newPayment(vendor, 100 * U);
        // approvals signed for `vault`, submitted to v2
        vm.expectRevert();
        v2.executePayment(p, _approvalsFor(vault, _hPayment(p), 1));
        // signed for v2: works
        v2.executePayment(p, _approvalsFor(v2, _hPayment(p), 1));
        assertEq(usdt.balanceOf(vendor), 100 * U);
    }

    function test_initialize_onlyFactoryAndOnlyOnce() public {
        OrgInit memory init = _defaultInit();
        vm.expectRevert(OrgVault.OnlyFactory.selector);
        vault.initialize(init);
        vm.prank(address(factory));
        vm.expectRevert(OrgVault.AlreadyInitialized.selector);
        vault.initialize(init);
        // the implementation itself is not initializable by a stranger
        vm.expectRevert(OrgVault.OnlyFactory.selector);
        impl.initialize(init);
    }

    function test_initialize_invalidInitsRevert() public {
        OrgInit memory init;

        init = _defaultInit();
        init.approvers = new address[](0);
        _expectCreateRevert(init, ApprovalsModule.InvalidApprovers.selector);

        init = _defaultInit();
        init.approvers[1] = init.approvers[0]; // duplicate
        _expectCreateRevert(init, ApprovalsModule.InvalidApprovers.selector);

        init = _defaultInit();
        init.approvers[0] = address(0);
        _expectCreateRevert(init, ApprovalsModule.InvalidApprovers.selector);

        init = _defaultInit();
        init.approvers = new address[](51);
        for (uint256 i; i < 51; ++i) {
            init.approvers[i] = address(uint160(0x1000 + i));
        }
        _expectCreateRevert(init, ApprovalsModule.InvalidApprovers.selector);

        init = _defaultInit();
        init.tiers[1].maxAmount = init.tiers[0].maxAmount; // not strictly ascending
        _expectCreateRevert(init, ApprovalsModule.InvalidTiers.selector);

        init = _defaultInit();
        init.tiers[2].maxAmount = 1_000_000 * 1e6; // last tier not unbounded
        _expectCreateRevert(init, ApprovalsModule.InvalidTiers.selector);

        init = _defaultInit();
        init.tiers[0].approvals = 0;
        _expectCreateRevert(init, ApprovalsModule.InvalidTiers.selector);

        init = _defaultInit();
        init.tiers = new Tier[](0);
        _expectCreateRevert(init, ApprovalsModule.InvalidTiers.selector);

        init = _defaultInit();
        init.payeeApprovals = 0;
        _expectCreateRevert(init, ApprovalsModule.InvalidGovernanceParams.selector);

        init = _defaultInit();
        init.governanceApprovals = 0;
        _expectCreateRevert(init, ApprovalsModule.InvalidGovernanceParams.selector);

        init = _defaultInit();
        init.budgets = new BudgetInit[](1);
        init.budgets[0] = BudgetInit(COMP, 1, 0); // GENERAL missing
        _expectCreateRevert(init, abi.encodeWithSelector(BudgetsModule.BudgetMissing.selector, GENERAL));

        init = _defaultInit();
        init.budgets[0].periodMonths = 121;
        _expectCreateRevert(init, BudgetsModule.InvalidBudget.selector);
    }

    function _expectCreateRevert(OrgInit memory init, bytes4 sel) internal {
        _expectCreateRevert(init, abi.encodePacked(sel));
    }

    function _expectCreateRevert(OrgInit memory init, bytes memory data) internal {
        usdt.mint(payer, 5 * U);
        OrgFactory.Auth memory auth = _authFor(payer, init, SALT2, payerPk);
        vm.expectRevert(data);
        factory.createOrg(payer, init, SALT2, auth);
    }

    function test_platformAdmin_onlyOwner() public {
        vm.startPrank(stranger);
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.expectRevert(unauthorized);
        factory.setOnboardingFee(1);
        vm.expectRevert(unauthorized);
        factory.setFeeRecipient(stranger);
        vm.expectRevert(unauthorized);
        factory.setImplementation(address(impl));
        vm.expectRevert(unauthorized);
        factory.setCreationPaused(true);
        vm.stopPrank();
    }

    function test_platformAdmin_setters() public {
        vm.startPrank(platformOwner);
        factory.setOnboardingFee(7 * U);
        assertEq(factory.onboardingFee(), 7 * U);
        factory.setFeeRecipient(stranger);
        assertEq(factory.feeRecipient(), stranger);
        vm.expectRevert(OrgFactory.ZeroAddress.selector);
        factory.setFeeRecipient(address(0));
        vm.expectRevert(OrgFactory.ZeroAddress.selector);
        factory.setImplementation(address(0));
        vm.stopPrank();
    }

    function test_setImplementation_mustBelongToThisFactory() public {
        OrgVault foreign = new OrgVault(makeAddr("otherFactory"), address(usdt), address(pool), address(pool.aToken()), U);
        vm.prank(platformOwner);
        vm.expectRevert(OrgFactory.WrongFactory.selector);
        factory.setImplementation(address(foreign));
    }

    function test_setImplementation_affectsOnlyNewOrgs() public {
        OrgVault impl2 = new OrgVault(address(factory), address(usdt), address(pool), address(pool.aToken()), 2 * U);
        vm.prank(platformOwner);
        factory.setImplementation(address(impl2));
        assertEq(vault.minSweepAmount(), 1 * U); // existing vault unchanged
        OrgVault v2 = _createOrg(_defaultInit(), SALT2);
        assertEq(v2.minSweepAmount(), 2 * U);
    }

    function test_platformOwnerHasNoPowerOverVaults() public {
        Payment memory p = _newPayment(platformOwner, 10 * U);
        vm.startPrank(platformOwner);
        vm.expectRevert();
        vault.executePayment(p, new Approval_[](0));
        vm.stopPrank();
        assertEq(usdt.balanceOf(platformOwner), 0);
    }

    function test_getOrgs_pagination() public {
        _createOrg(_defaultInit(), SALT2);
        _createOrg(_defaultInit(), bytes32(uint256(3)));
        assertEq(factory.orgCount(), 3);
        assertEq(factory.getOrgs(1, 10).length, 2);
        assertEq(factory.getOrgs(0, 1).length, 1);
        assertEq(factory.getOrgs(5, 1).length, 0);
    }
}

// alias so the empty-array literal above reads naturally
import {Approval as Approval_} from "../src/OrgTypes.sol";
