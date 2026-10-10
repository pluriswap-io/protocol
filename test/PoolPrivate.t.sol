// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods,
    PackageData
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";
import {ArbiterRegistry} from "../src/packages/ArbiterRegistry.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {VouchData} from "../src/packages/libraries/VouchData.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {BundleVerifierMock} from "../mocks/BundleVerifierMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {DepositVerifierMock} from "../mocks/DepositVerifierMock.sol";
import {ReabsorbVerifierMock} from "../mocks/ReabsorbVerifierMock.sol";
import {WithdrawVerifierMock} from "../mocks/WithdrawVerifierMock.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";
import {BaseTest} from "./Base.t.sol";

/// @title A pool on the official private stack — a peer like any other
/// @notice PROTOCOLO.md Anexo R, 2026-10-05. Each side of a deal is an ACCOUNT (reputation, tier, cap, bond,
///         penalties) and an OPERATOR (the human who acts). In a person they are the same; in a pool the account is
///         the pool and the operator is its Controller. So a pool:
///           * climbs the same ladder as a person, in the clear: a concurrent cap that starts at T1 and rises with
///             its score and its bond, credit once per distinct Provider, sixteen credits per epoch, the same
///             penalties;
///           * carries its own bond, public, out of its own capital, counted in its NAV;
///           * always acts through a verified operator: every pool side is the vouch of the deal's Controller,
///             who registered its operator tag in the pool.
///         End to end with a real official pool, the real factory and the real private modules (verifiers mocked:
///         a mock is not privacy).
contract PoolPrivateTest is BaseTest {
    uint256 internal constant ACT_BPS = 30;
    uint256 internal constant TOKENS = 1e6; // one whole token of the 6-decimals test token
    address internal constant FEE_TO = address(0xFEE);
    bytes32 internal constant SUBJECT_P = bytes32(uint256(0x52));
    bytes32 internal constant REGISTRY_ID = keccak256("pluri:humanity-registry:v1");
    bytes32 internal constant OP_TAG = bytes32(uint256(0x0b0b));
    bytes32 internal constant CP_TAG = bytes32(uint256(0xc0c0));

    PoolFactory internal factory;
    Pool internal pool;
    PoseidonTree internal tree;
    BundleVerifierMock internal bundle;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;
    PrivateBondVault internal vault;
    ArbiterRegistry internal panel;
    address internal lp = address(0x11);
    uint256[3] internal pks = [uint256(0xA1), uint256(0xA2), uint256(0xA3)];
    address[3] internal arbs;
    bytes32[3] internal hns = [keccak256("hn-1"), keccak256("hn-2"), keccak256("hn-3")];
    /// @dev Knobs a test turns before building a deal. Off by default: every flow means verified accounts, the
    ///      registered operator, one Provider, no bonds, no court.
    bool internal openProvider;
    bool internal openOperator;
    bool internal bonded;
    bytes32 internal cpTag = CP_TAG;
    uint256 internal noteSeq;

    function setUp() public override {
        PoseidonSingletons.install();
        super.setUp();
        factory = new PoolFactory(address(escrow));
        HumanityVerifierMock humanity = new HumanityVerifierMock();
        AccountVerifierMock account = new AccountVerifierMock();
        bundle = new BundleVerifierMock();
        ClaimVerifierMock claim = new ClaimVerifierMock();
        DepositVerifierMock deposit = new DepositVerifierMock();
        ReabsorbVerifierMock reabsorb = new ReabsorbVerifierMock();
        WithdrawVerifierMock withdraw = new WithdrawVerifierMock();
        uint256 n = vm.getNonce(address(this));
        address predictedRep = vm.computeCreateAddress(address(this), n + 2);
        address predictedVault = vm.computeCreateAddress(address(this), n + 3);
        tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        passport = new PrivatePassport(tree, humanity, bundle, address(factory));
        reputation = new PrivateReputation(
            passport,
            tree,
            account,
            bundle,
            claim,
            FEE_TO,
            ACT_BPS,
            0,
            0,
            0,
            address(escrow),
            predictedVault,
            0,
            address(0)
        );
        vault = new PrivateBondVault(
            passport, reputation, address(0xdeaD), address(escrow), deposit, bundle, reabsorb, withdraw
        );
        assertEq(address(reputation), predictedRep);
        assertEq(address(vault), predictedVault);
        panel = new ArbiterRegistry(
            address(escrow),
            address(token),
            ArbiterRegistry.Policy(1 days, 1 days, 7 days, 1_000, 5_000, 20, 3_000),
            address(0),
            address(vault),
            address(humanity),
            address(bundle),
            REGISTRY_ID,
            address(factory)
        );
        for (uint256 i; i < 3; i++) {
            arbs[i] = vm.addr(pks[i]);
            token.mint(arbs[i], 10_000 * TOKENS);
            vm.startPrank(arbs[i]);
            token.approve(address(panel), type(uint256).max);
            panel.deposit(10_000 * TOKENS);
            panel.registerHumanity(abi.encode(true), hns[i]);
            panel.setEncryptionKey(keccak256(abi.encode("x25519", i)));
            vm.stopPrank();
        }

        address[] memory sps = new address[](1);
        sps[0] = holder;
        address[] memory cs = new address[](1);
        cs[0] = controller;
        address[] memory none = new address[](0);
        pool = Pool(factory.createPool(sps, address(token), cs, true, none, 0));
        token.mint(lp, 2_000 * TOKENS);
        vm.startPrank(lp);
        token.approve(address(pool), type(uint256).max);
        pool.deposit(2_000 * TOKENS);
        vm.stopPrank();
        vm.prank(controller);
        pool.setOperatorTag(OP_TAG);

        token.mint(provider, 1_000 * TOKENS);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
    }

    // --- the operator: a pool acts through its verified Controller ---------------------------------------

    function test_aPoolSide_needsItsOperatorsVouch() public {
        _expectActivateRevert("", 1, PRINCIPAL, false, PrivatePassport.OperatorRequired.selector);
    }

    function test_aVouchByAnotherOperator_isRefused() public {
        IBundleVerifier.VouchInputs memory v = _vouch(keccak256("pair"), [bytes32(0), 0, 0]);
        v.operatorTag = bytes32(uint256(0xbad));
        _expectActivateRevert(
            VouchData.encode(v, abi.encode(true)), 1, PRINCIPAL, false, PrivatePassport.OperatorMismatch.selector
        );
    }

    function test_aVouchForAnotherPool_isRefused() public {
        IBundleVerifier.VouchInputs memory v = _vouch(keccak256("pair"), [bytes32(0), 0, 0]);
        v.poolId = keccak256("another pool");
        _expectActivateRevert(
            VouchData.encode(v, abi.encode(true)), 1, PRINCIPAL, false, PrivatePassport.PoolMismatch.selector
        );
    }

    /// Every operator of a pool is a verified human: an open account cannot act for a pool.
    function test_anOpenOperator_isRefused() public {
        openOperator = true;
        _expectActivateRevert(
            _vouchFor(keccak256("pair")), 1, PRINCIPAL, false, PrivatePassport.OperatorNotVerified.selector
        );
    }

    function test_aControllerWithoutAnOperatorTag_cannotAuthorize() public {
        address other = address(0x0C2);
        vm.prank(holder);
        pool.setController(other, true);
        DealTerms memory t = _terms(PRINCIPAL, false);
        t.controller = other;
        HolderAuthorization memory ha = _holderAuth(t, 1);
        PackageMods memory mods = _mods(false);
        vm.prank(other);
        vm.expectRevert(Pool.OperatorUnregistered.selector);
        pool.authorize(ha, mods);
    }

    function test_setOperatorTag_onlyAnAgent() public {
        vm.prank(lp);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.setOperatorTag(OP_TAG);
        assertEq(pool.operatorTagOf(controller), OP_TAG);
    }

    function test_theReputationChecksTheVouchItself() public {
        bundle.setVouchAnswer(false);
        _expectActivateRevert(
            _vouchFor(keccak256("pair")), 1, PRINCIPAL, false, PrivateReputation.AdmitProofFailed.selector
        );
    }

    /// The vouch has to name the pair the Provider named: the module compares the two tags exactly as it does
    /// between two people.
    function test_aVouchForAnotherPair_isRefused() public {
        _expectActivateRevert(
            _vouchFor(keccak256("another pair")), 1, PRINCIPAL, false, PrivateReputation.PairMismatch.selector
        );
    }

    function test_aVouchForAnotherDeal_isRefused() public {
        IBundleVerifier.VouchInputs memory v = _vouch(keccak256("pair"), [bytes32(0), 0, 0]);
        v.dealId = keccak256("another deal");
        _expectActivateRevert(
            VouchData.encode(v, abi.encode(true)), 1, PRINCIPAL, false, PrivatePassport.DealMismatch.selector
        );
    }

    function test_aVouchNobodyProved_isRefused() public {
        IBundleVerifier.VouchInputs memory v = _vouch(keccak256("pair"), [bytes32(0), 0, 0]);
        _expectActivateRevert(
            VouchData.encode(v, abi.encode(false)), 1, PRINCIPAL, false, PrivatePassport.PassportProofFailed.selector
        );
    }

    /// A pool's side is its operator's vouch — never a person's account standing in as the pool.
    function test_aPersonSideForAPool_isRefused() public {
        IBundleVerifier.BundleInputs memory i = _provider(bytes32(0), PRINCIPAL);
        _expectActivateRevert(
            abi.encode(i, abi.encode(true)), 1, PRINCIPAL, false, PrivatePassport.PoolSideNotAVouch.selector
        );
    }

    /// And a vouch is only ever a pool's side: a person proves their own account.
    function test_aVouchForAPerson_isRefused() public {
        bytes memory v = _vouchFor(keccak256("pair"));
        vm.expectRevert(PrivatePassport.NotAPool.selector);
        passport.identify(holder, holder, keccak256("a deal"), v);
    }

    function test_aCloneTheFactoryDidNotMake_isNoPool() public view {
        assertEq(passport.poolSubjectOf(address(0xBEEF)), bytes32(0));
        assertTrue(passport.poolSubjectOf(address(pool)) != bytes32(0));
    }

    // --- the pool's reputation: the same ladder, in the clear -------------------------------------------

    function test_aPoolDeal_recordsAndCreditsThePool_andCreditsTheProvider() public {
        (bytes32 id, IReputation.Close kind) = _tradeAndRelease(1, PRINCIPAL);
        bytes32 poolSubject = _poolSubject();
        (uint256 count, uint256 volume,) = reputation.poolStats(poolSubject, address(token));
        assertEq(count, 1, "the pool's record, in the clear");
        assertEq(volume, PRINCIPAL);
        (uint256 credits, uint256 creditVolume) = reputation.poolCredit(poolSubject, address(token));
        assertEq(credits, 1, "and its credit: a new Provider vouched for it by trading");
        assertEq(creditVolume, PRINCIPAL);
        assertTrue(kind == IReputation.Close.Peaceful, "the Provider's record takes the deal");
        assertTrue(reputation.creditable(id), "a verified operator and a verified Provider: it credits");
        assertEq(reputation.poolInFlight(poolSubject, address(token)), 0, "the cap is free again");
    }

    /// Credit is once per counterparty, as between people: the same Provider again records, and does not credit.
    function test_thePoolIsCreditedOncePerProvider() public {
        _tradeAndRelease(1, PRINCIPAL);
        _tradeAndRelease(2, PRINCIPAL);
        (uint256 count,,) = reputation.poolStats(_poolSubject(), address(token));
        (uint256 credits,) = reputation.poolCredit(_poolSubject(), address(token));
        assertEq(count, 2, "both deals record");
        assertEq(credits, 1, "one Provider, one credit");
        cpTag = bytes32(uint256(0xc0c1));
        _tradeAndRelease(3, PRINCIPAL);
        (credits,) = reputation.poolCredit(_poolSubject(), address(token));
        assertEq(credits, 2, "another Provider credits again");
    }

    function test_anOpenProvider_recordsButNeverCredits() public {
        openProvider = true;
        (bytes32 id,) = _tradeAndRelease(1, PRINCIPAL);
        assertFalse(reputation.creditable(id));
        (uint256 count,,) = reputation.poolStats(_poolSubject(), address(token));
        (uint256 credits,) = reputation.poolCredit(_poolSubject(), address(token));
        assertEq(count, 1);
        assertEq(credits, 0, "an open Provider is not a human vouching for the pool");
    }

    /// A pool no longer skips the ladder: a new one starts at T1, 250 tokens open at once, whatever its capital.
    function test_aNewPool_startsAtT1() public {
        assertEq(reputation.poolCap(_poolSubject(), address(token), false), 250 * TOKENS);
        _expectActivateRevert(
            _vouchFor(keccak256("pair")), 1, 251 * TOKENS, false, PrivateReputation.CapExceeded.selector
        );
        _activate(_vouchFor(keccak256("pair")), 2, 250 * TOKENS, false);
    }

    /// The cap is concurrent: what is open counts against it.
    function test_thePoolsCapIsConcurrent() public {
        _activate(_vouchFor(keccak256("pair")), 1, 200 * TOKENS, false);
        assertEq(reputation.poolInFlight(_poolSubject(), address(token)), 200 * TOKENS);
        _expectActivateRevert(
            _vouchFor(keccak256("pair")), 2, 100 * TOKENS, false, PrivateReputation.CapExceeded.selector
        );
        _activate(_vouchFor(keccak256("pair")), 3, 50 * TOKENS, false);
    }

    /// The bond column, as for a person: with its own lock behind every open deal, T1 is 400.
    function test_theBondColumn_raisesThePoolsCap() public {
        bonded = true;
        _fundPoolBond(100 * TOKENS);
        assertEq(reputation.poolCap(_poolSubject(), address(token), true), 400 * TOKENS);
        _activate(_vouchFor(keccak256("pair")), 1, 300 * TOKENS, false);
        assertEq(reputation.poolInFlight(_poolSubject(), address(token)), 300 * TOKENS);
    }

    /// Penalties land on the account — the pool — and take its tier down like anyone's.
    function test_aDeadlock_penalizesThePool() public {
        bytes32 id = _activate(_vouchFor(keccak256("pair")), 1, PRINCIPAL, false);
        _markFiat(id);
        vm.prank(controller);
        escrow.openDisputed(id);
        vm.warp(block.timestamp + 7200);
        escrow.forceDisputeTimeout(id);
        (,, uint256 penalty) = reputation.poolStats(_poolSubject(), address(token));
        assertEq(penalty, 10);
        assertEq(reputation.poolScore(_poolSubject(), address(token)), 0);
    }

    /// The Provider across from a pool goes into the tree alone, with the pair it named kept for its claim.
    function test_theProviderIsAdmittedAlone() public {
        uint256 leavesBefore = tree.nextIndex();
        bytes32 id = _activate(_vouchFor(keccak256("pair")), 1, PRINCIPAL, false);
        assertEq(tree.nextIndex(), leavesBefore + 1, "the Provider's leaf goes in alone");
        assertEq(reputation.pairTagOf(id), keccak256("pair"));
        (bytes32 subjectH,) = escrow.subjects(id);
        assertEq(subjectH, _poolSubject(), "the pool's subject is its address's");
    }

    /// Penalties apply against a pool's counterparty too: a Provider who never showed up is marked.
    function test_aProviderWhoNeverShowedUp_isMarked() public {
        bytes32 id = _activate(_vouchFor(keccak256("pair")), 1, PRINCIPAL, false);
        vm.warp(block.timestamp + 3600);
        escrow.timeoutFiat(id);
        (IReputation.Close kind,,) = reputation.pending(_providerSubject(id));
        assertTrue(kind == IReputation.Close.NoShow);
        assertEq(reputation.poolInFlight(_poolSubject(), address(token)), 0, "and the pool's cap is free again");
    }

    // --- the pool's bond: public, out of its own capital -------------------------------------------------

    function test_thePoolFundsItsBond_fromIdle_andItStaysInTheNav() public {
        uint256 navBefore = pool.nav();
        uint256 idleBefore = pool.idle();
        _fundPoolBond(100 * TOKENS);
        assertEq(pool.idle(), idleBefore - 100 * TOKENS, "out of idle");
        assertEq(vault.poolBondOf(address(pool), address(token)), 100 * TOKENS, "into the vault, in the pool's name");
        assertEq(pool.nav(), navBefore, "still the LPs' money");
        vm.prank(holder);
        pool.withdrawBond(40 * TOKENS);
        assertEq(pool.idle(), idleBefore - 60 * TOKENS, "back into idle");
        assertEq(pool.nav(), navBefore);
    }

    function test_fundBond_onlyASponsor() public {
        vm.prank(controller);
        vm.expectRevert(Pool.Unauthorized.selector);
        pool.fundBond(address(vault), 1);
    }

    function test_depositPool_onlyForAnOfficialPool() public {
        token.mint(address(this), 1);
        token.approve(address(vault), 1);
        vm.expectRevert(PrivateBondVault.NotAPool.selector);
        vault.depositPool(address(0xBEEF), address(token), 1);
    }

    function test_aBondedPoolDeal_locksThePoolsBond_andReleasesIt() public {
        bonded = true;
        _fundPoolBond(100 * TOKENS);
        bytes32 id = _activate(_vouchFor(keccak256("pair")), 1, PRINCIPAL, false);
        uint256 lock = PRINCIPAL / 10;
        assertEq(vault.poolFreeOf(address(pool), address(token)), 100 * TOKENS - lock, "the lock left the free bond");
        assertEq(vault.poolBondOf(address(pool), address(token)), 100 * TOKENS, "still the pool's");
        _markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        assertEq(vault.poolFreeOf(address(pool), address(token)), 100 * TOKENS, "a public lock comes back at once");
    }

    /// The panel is paid out of the bonds, and a pool that loses pays like anyone: its lock goes to the Provider,
    /// minus the court's share, and the LPs' NAV carries the loss.
    function test_aPoolThatLosesInCourt_losesItsLock() public {
        bonded = true;
        _fundPoolBond(100 * TOKENS);
        bytes32 id = _activate(_vouchFor(keccak256("pair"), hns), 1, PRINCIPAL, true);
        _markFiat(id);
        vm.prank(controller);
        escrow.openCourt(id);
        uint256 navBefore = pool.nav();
        _rule(id, 2);
        escrow.readRuling(id);
        uint256 lock = PRINCIPAL / 10;
        uint256 cut = lock * 3_000 / 10_000;
        assertEq(vault.poolBondOf(address(pool), address(token)), 100 * TOKENS - lock, "the pool's lock is gone");
        assertEq(token.balanceOf(provider), 1_000 * TOKENS - lock + PRINCIPAL + lock - cut, "principal and 70%");
        assertEq(pool.nav(), navBefore - PRINCIPAL - lock, "the LPs carry it");
        (,, uint256 penalty) = reputation.poolStats(_poolSubject(), address(token));
        assertEq(penalty, 15, "and the pool's record");
    }

    /// A pool that wins keeps what the losing Provider's lock pays, in its own bond.
    function test_aPoolThatWinsInCourt_takesTheProvidersLock_intoItsBond() public {
        bonded = true;
        _fundPoolBond(100 * TOKENS);
        bytes32 id = _activate(_vouchFor(keccak256("pair"), hns), 1, PRINCIPAL, true);
        _markFiat(id);
        vm.prank(controller);
        escrow.openCourt(id);
        _rule(id, 1);
        escrow.readRuling(id);
        uint256 lock = PRINCIPAL / 10;
        uint256 cut = lock * 3_000 / 10_000;
        assertEq(
            vault.poolBondOf(address(pool), address(token)), 100 * TOKENS + lock - cut, "70% of the Provider's lock"
        );
        assertEq(vault.poolFreeOf(address(pool), address(token)), 100 * TOKENS + lock - cut, "and its own back");
    }

    // --- the panel across from a pool ---------------------------------------------------------------------

    function test_aPoolSitsWithTheHumanPanel_withItsBond() public {
        bonded = true;
        _fundPoolBond(100 * TOKENS);
        bytes32 id = _activate(_vouchFor(keccak256("pair"), hns), 1, PRINCIPAL, true);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED), "activated with the panel");
    }

    /// No bonds, no panel: the arbiters are paid out of them.
    function test_aPanelDealWithoutBonds_isRefused() public {
        _expectActivateRevert(
            _vouchFor(keccak256("pair"), hns), 1, PRINCIPAL, true, ArbiterRegistry.BondsRequired.selector
        );
    }

    function test_aVouchForAnotherPanel_isRefused() public {
        bonded = true;
        _fundPoolBond(100 * TOKENS);
        bytes32[3] memory other = [hns[0], hns[1], keccak256("somebody else")];
        _expectActivateRevert(
            _vouchFor(keccak256("pair"), other), 1, PRINCIPAL, true, ArbiterRegistry.PanelMismatch.selector
        );
    }

    // --- helpers ----------------------------------------------------------------------------------------

    function _poolSubject() internal view returns (bytes32) {
        return passport.poolSubjectOf(address(pool));
    }

    function _fundPoolBond(uint256 amount) internal {
        vm.prank(holder);
        pool.fundBond(address(vault), amount);
    }

    function _terms(uint256 principal, bool withCourt) internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.holder = address(pool);
        t.controller = controller;
        t.principal = principal;
        uint256 n = 2 + (bonded ? 1 : 0) + (withCourt ? 1 : 0);
        bytes32[] memory ids = new bytes32[](n);
        ids[0] = PackageId.passport(address(passport));
        ids[1] = reputation.packageId();
        uint256 k = 2;
        if (bonded) ids[k++] = vault.packageId();
        if (withCourt) {
            ids[k++] = panel.packageId();
            t.arbitrationDuration = 3 days;
        }
        t.packageIds = _sortIds(ids);
    }

    function _mods(bool withCourt) internal view returns (PackageMods memory mods) {
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        if (bonded) mods.bonds = address(vault);
        if (withCourt) mods.court = address(panel);
    }

    /// Authorizes and prepares the activation of a pool deal; `side` is the pool's side of `PackageData`, built
    /// before the deal id is known and stamped with it here.
    function _prepare(bytes memory side, uint256 nonce, uint256 principal, bool withCourt)
        internal
        returns (
            HolderAuthorization memory ha,
            ProviderAgreement memory pa,
            ControllerAcceptance memory ca,
            PackageMods memory mods,
            PackageData memory data
        )
    {
        DealTerms memory t = _terms(principal, withCourt);
        mods = _mods(withCourt);
        ha = _holderAuth(t, nonce);
        pa = _providerAuth(t, nonce);
        ca = _controllerAuth(t, nonce);
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, nonce, nonce, nonce);
        vm.prank(controller);
        pool.authorize(ha, mods);

        data.holder = _stamp(side, id);
        IBundleVerifier.BundleInputs memory p = _provider(id, principal);
        if (withCourt) {
            p.registryId = REGISTRY_ID;
            p.arbiters = hns;
        }
        data.provider = abi.encode(p, abi.encode(true));
        if (withCourt) data.court = _appointment(id, nonce);
    }

    function _activate(bytes memory side, uint256 nonce, uint256 principal, bool withCourt) internal returns (bytes32) {
        (
            HolderAuthorization memory ha,
            ProviderAgreement memory pa,
            ControllerAcceptance memory ca,
            PackageMods memory mods,
            PackageData memory data
        ) = _prepare(side, nonce, principal, withCourt);
        return escrow.activate(ha, "", pa, _signProvider(pa), ca, _signController(ca), mods, data);
    }

    function _expectActivateRevert(bytes memory side, uint256 nonce, uint256 principal, bool withCourt, bytes4 selector)
        internal
    {
        (
            HolderAuthorization memory ha,
            ProviderAgreement memory pa,
            ControllerAcceptance memory ca,
            PackageMods memory mods,
            PackageData memory data
        ) = _prepare(side, nonce, principal, withCourt);
        bytes memory ps = _signProvider(pa);
        bytes memory cs = _signController(ca);
        vm.expectRevert(selector);
        escrow.activate(ha, "", pa, ps, ca, cs, mods, data);
    }

    function _tradeAndRelease(uint256 nonce, uint256 principal) internal returns (bytes32 id, IReputation.Close kind) {
        id = _activate(_vouchFor(keccak256("pair")), nonce, principal, false);
        _markFiat(id);
        vm.prank(controller);
        escrow.release(id);
        (kind,,) = reputation.pending(_providerSubject(id));
        pool.reconcile(nonce);
    }

    /// Every arbiter votes `vote`, and the case is decided at once.
    function _rule(bytes32 id, uint8 vote) internal {
        for (uint256 i; i < 3; i++) {
            vm.prank(arbs[i]);
            panel.commit(id, keccak256(abi.encode(id, arbs[i], vote, bytes32(i))));
        }
        for (uint256 i; i < 3; i++) {
            vm.prank(arbs[i]);
            panel.reveal(id, vote, bytes32(i));
        }
    }

    /// The panel's appointment, signed by the Provider, the three arbiters and — through the Controller — the pool.
    function _appointment(bytes32 id, uint256 nonce) internal returns (bytes memory) {
        bytes32 digest = panel.appointmentDigest(id, arbs);
        vm.prank(controller);
        pool.approveCourtDigest(nonce, digest);
        bytes[3] memory accepts;
        for (uint256 k; k < 3; k++) {
            accepts[k] = _sign(digest, pks[k]);
        }
        return abi.encode(arbs, bytes(""), _sign(digest, providerPk), accepts);
    }

    function _vouch(bytes32 pairTag, bytes32[3] memory panelHns)
        internal
        view
        returns (IBundleVerifier.VouchInputs memory v)
    {
        v.repRoot = tree.root();
        v.pairTag = pairTag;
        v.registryId = REGISTRY_ID;
        v.arbiters = panelHns;
        v.verified = !openOperator;
        v.poolId = _poolSubject();
        v.operatorTag = OP_TAG;
        v.cpTag = cpTag;
    }

    function _vouchFor(bytes32 pairTag) internal view returns (bytes memory) {
        return _vouchFor(pairTag, [bytes32(0), 0, 0]);
    }

    function _vouchFor(bytes32 pairTag, bytes32[3] memory panelHns) internal view returns (bytes memory) {
        return VouchData.encode(_vouch(pairTag, panelHns), abi.encode(true));
    }

    /// A vouch built before the deal id exists gets it stamped in; one that already names a deal keeps it.
    function _stamp(bytes memory side, bytes32 id) internal view returns (bytes memory) {
        if (side.length < 32 || bytes32(side) != VouchData.TAG) return side;
        (IBundleVerifier.VouchInputs memory v, bytes memory proof) = this.decodeVouch(side);
        if (v.dealId == bytes32(0)) v.dealId = id;
        return VouchData.encode(v, proof);
    }

    function decodeVouch(bytes calldata side) external pure returns (IBundleVerifier.VouchInputs memory, bytes memory) {
        return VouchData.decode(side);
    }

    /// The Provider's deal subject is per deal, as a real `prepare_side` derives it.
    function _providerSubject(bytes32 id) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(SUBJECT_P, id))) >> 8);
    }

    /// The Provider's side; bonded when the deal is, out of a note deposited for it.
    function _provider(bytes32 id, uint256 principal) internal returns (IBundleVerifier.BundleInputs memory i) {
        i.dealSubject = _providerSubject(id);
        i.dealId = id;
        i.token = address(token);
        i.principal = principal;
        i.repRoot = tree.root();
        i.newLeaf = bytes32(uint256(0x62) + noteSeq);
        i.nullRep = keccak256(abi.encode("nullrep-p", id));
        i.pairTag = keccak256("pair");
        i.verified = !openProvider;
        if (bonded && id != bytes32(0)) {
            uint256 lock = (principal + 9) / 10;
            noteSeq++;
            bytes32 note = bytes32(uint256(0x7000) + noteSeq);
            vm.prank(provider);
            vault.deposit(address(token), lock, note, abi.encode(true));
            i.lockCommit = bytes32(uint256(0x8000) + noteSeq);
            i.lockAmount = lock;
            i.changeNote = bytes32(uint256(0x9000) + noteSeq);
            i.nullBond = keccak256(abi.encode("nullbond-p", id));
            i.bondRoot = vault.bondRoot();
        }
    }
}
