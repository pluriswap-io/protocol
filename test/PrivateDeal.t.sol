// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
import {Escrow} from "../src/Escrow.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IPrivateReputation} from "../src/packages/interfaces/IPrivateReputation.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY, MIN_ROOT_HISTORY, MAX_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {BundleVerifierMock} from "../mocks/BundleVerifierMock.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {IClaimVerifier} from "../src/packages/interfaces/IClaimVerifier.sol";
import {DepositVerifierMock} from "../mocks/DepositVerifierMock.sol";
import {ReabsorbVerifierMock} from "../mocks/ReabsorbVerifierMock.sol";
import {WithdrawVerifierMock} from "../mocks/WithdrawVerifierMock.sol";
import {EthCourtMock} from "../mocks/EthCourtMock.sol";
import {RelayerMock} from "../mocks/RelayerMock.sol";
import {BaseTest} from "./Base.t.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";

/// @title Private deal tests (F2, PROTOCOLO.md §E.3.15.4–E.3.15.5)
/// @dev The private package set (PrivatePassport + PrivateReputation) against the real kernel:
///      the activation bundle is one tx, admit consumes the buffer, terminals pend one delta per
///      deal subject, claim applies it once. Verifier mocks decode the proof as a bool: a passing
///      mock is not privacy, and nothing here claims it is.
///
///      Test hygiene: every external call that feeds a reverting call (roots, signatures, sides)
///      is hoisted to a local BEFORE `vm.expectRevert` — the expectation is consumed by the next
///      call, whatever it is.
contract PrivateDealTest is BaseTest {
    /// @dev One side's public inputs, as the merged `prepare_side` proof would carry them
    ///      (§E.3.15.4). With a mock verifier nothing checks their internal consistency — what these
    ///      tests exercise is the MODULES: that each one reads its own half out of a side that was
    ///      proven, and refuses one that was not.
    ///      Building a side here also PROVES it: with a mock verifier the proof is a formality, and
    ///      these suites are about what the modules do with a side that was proven. The suites that
    ///      care about the proof itself (`BundleVerifier.t.sol`, `PrepareRealProof.t.sol`) use the
    ///      real adapter and the committed fixture, and one of them pins the no-ticket case.
    function _in(bytes32 subject, bytes32 leaf, bytes32 nullifier, bytes32 root, bytes32 forDealId)
        internal
        view
        returns (IBundleVerifier.BundleInputs memory)
    {
        return IBundleVerifier.BundleInputs({
            dealSubject: subject,
            dealId: forDealId,
            token: address(token),
            principal: PRINCIPAL,
            repRoot: root,
            newLeaf: leaf,
            nullRep: nullifier,
            pairTag: PAIR_TAG,
            lockCommit: bytes32(0),
            lockAmount: 0,
            changeNote: bytes32(0),
            nullBond: bytes32(0),
            bondRoot: bytes32(0),
            registryId: bytes32(0),
            hintS: bytes32(0),
            hintK: bytes32(0),
            arbiters: [bytes32(0), bytes32(0), bytes32(0)],
            verified: true
        });
    }

    /// @dev The §E.3.14.7 pair tag. With a mock verifier nothing checks its VALUE — what these tests
    ///      exercise is that both sides of one activation carry the SAME one, which is what the module
    ///      compares. The real value is pinned by the fixture tests and by the circuit itself.
    bytes32 internal constant PAIR_TAG = keccak256("pluri:test:pair-tag");

    /// @dev A fresh deal id / counterparty per call: these tests predate the 2026-09-23 rule that credit
    ///      is once per counterparty, and they all mean "another deal with somebody new". The ones that
    ///      mean "the same somebody again" say so by passing a fixed tag.
    uint256 private _tagNonce;

    function _dealTag() internal returns (bytes32) {
        return keccak256(abi.encode("deal", ++_tagNonce));
    }

    function _cpTag() internal returns (bytes32) {
        return keccak256(abi.encode("counterparty", ++_tagNonce));
    }

    bytes32 internal constant HN_H = keccak256("human-h");
    bytes32 internal constant HN_P = keccak256("human-p");
    bytes32 internal constant LEAF0_H = bytes32(uint256(0x1001));
    bytes32 internal constant LEAF0_P = bytes32(uint256(0x1002));
    bytes32 internal constant SUBJECT_H = bytes32(uint256(0x51));
    bytes32 internal constant SUBJECT_P = bytes32(uint256(0x52));
    bytes32 internal constant ADMIT_LEAF_H = bytes32(uint256(0x61));
    bytes32 internal constant ADMIT_LEAF_P = bytes32(uint256(0x62));
    bytes32 internal constant CLAIM_LEAF_H = bytes32(uint256(0x71));
    bytes32 internal constant NULLREP_H1 = keccak256("nullrep-h-1");
    bytes32 internal constant NULLREP_P1 = keccak256("nullrep-p-1");
    bytes32 internal constant NULLREP_H2 = keccak256("nullrep-h-2");
    bytes32 internal constant FAKE_ROOT = keccak256("fake-root");
    address internal constant FEE_TO = address(0xFEE);
    address internal constant SINK = address(0xDEAD);
    // Bond pieces (F3): one note per side funding the split, the lock commitments, the reabsorb.
    uint256 internal constant LOCK = (PRINCIPAL + 9) / 10; // §E.3.14.5, same curve as the public vault
    bytes32 internal constant DEPOSIT_NOTE_H = bytes32(uint256(0x2001));
    bytes32 internal constant DEPOSIT_NOTE_P = bytes32(uint256(0x2002));
    bytes32 internal constant CHANGE_H = bytes32(uint256(0x2101));
    bytes32 internal constant CHANGE_P = bytes32(uint256(0x2102));
    bytes32 internal constant LOCKCOMMIT_H = bytes32(uint256(0x3101));
    bytes32 internal constant LOCKCOMMIT_P = bytes32(uint256(0x3102));
    bytes32 internal constant NULLBOND_H1 = keccak256("nullbond-h-1");
    bytes32 internal constant NULLBOND_P1 = keccak256("nullbond-p-1");
    bytes32 internal constant REABSORB_NOTE_H = bytes32(uint256(0x2201));
    bytes32 internal constant NULLBOND_H2 = keccak256("nullbond-h-2");

    HumanityVerifierMock internal humanity;
    AccountVerifierMock internal account;
    BundleVerifierMock internal bundle;
    ClaimVerifierMock internal claimProof;
    DepositVerifierMock internal depositProof;
    ReabsorbVerifierMock internal reabsorbProof;
    WithdrawVerifierMock internal withdrawProof;
    RelayerMock internal relayer;
    PoseidonTree internal tree;
    PrivatePassport internal passport;
    PrivateReputation internal reputation;
    PrivateBondVault internal vault;
    PoolFactoryStub internal poolFactory;

    HolderAuthorization internal ha;
    ProviderAgreement internal pa;
    PackageMods internal mods;
    bytes32 internal dealId;
    HolderAuthorization internal bondHa;
    ProviderAgreement internal bondPa;
    PackageMods internal bondMods;
    bytes32 internal bondDealId;

    /// @dev Frozen fees here; `PrivateReputationGovernanceTest` runs this whole suite again under a governor.
    function _repGovernor() internal view virtual returns (address) {
        return address(0);
    }

    function setUp() public virtual override {
        // The private layer hashes through the pinned poseidon-solidity singletons, which a test
        // EVM starts without (PROTOCOLO.md §E.5.1).
        PoseidonSingletons.install();
        super.setUp();
        humanity = new HumanityVerifierMock();
        account = new AccountVerifierMock();
        bundle = new BundleVerifierMock();
        claimProof = new ClaimVerifierMock();
        depositProof = new DepositVerifierMock();
        reabsorbProof = new ReabsorbVerifierMock();
        withdrawProof = new WithdrawVerifierMock();
        relayer = new RelayerMock();
        // The accounts tree is wired before its owner exists: predict PrivateReputation's address
        // (tree, passport, vault, then reputation itself consume the next four nonces — the vault
        // is deployed between them, so it can hold the predicted reputation for its reabsorb
        // gating while the reputation holds the actual vault for its admit binding). The notes
        // tree needs no prediction: the vault deploys it for itself. The operator is the kernel:
        // reserve/unlock/slash/burn and admit/notifyTerminal must only ever answer the escrow's
        // context.
        address predictedRep = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        poolFactory = new PoolFactoryStub();
        passport = new PrivatePassport(tree, humanity, bundle, address(poolFactory));
        vault = new PrivateBondVault(
            passport,
            IPrivateReputation(predictedRep),
            SINK,
            address(escrow),
            depositProof,
            bundle,
            reabsorbProof,
            withdrawProof
        );
        reputation = new PrivateReputation(
            passport,
            tree,
            account,
            bundle,
            claimProof,
            FEE_TO,
            0,
            0,
            0,
            0,
            address(escrow),
            address(vault),
            0,
            _repGovernor()
        );
        assertEq(address(reputation), predictedRep, "predicted tree owner drifted");

        // Two registered humans, two initial leaves.
        passport.register(ok(true), HN_H);
        reputation.register(ok(true), HN_H, LEAF0_H);
        passport.register(ok(true), HN_P);
        reputation.register(ok(true), HN_P, LEAF0_P);

        ha = _holderAuth(_privateTerms(), 1);
        pa = _providerAuth(_privateTerms(), 1);
        mods = _mods(address(passport), address(reputation));
        dealId = Consent.dealId(escrow.domainSeparator(), _privateTerms(), 1, 1, 0);
        bondHa = _holderAuth(_bondTerms(), 1);
        bondPa = _providerAuth(_bondTerms(), 1);
        bondMods = _bondMods();
        bondDealId = Consent.dealId(escrow.domainSeparator(), _bondTerms(), 1, 1, 0);
    }

    function ok(bool pass) internal pure returns (bytes memory) {
        return abi.encode(pass);
    }

    function _privateTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        // The kernel signs a strictly ascending id list (Terms.UnsortedPackageIds): the relayer
        // sorts the private set the same way.
        bytes32 id0 = PackageId.passport(address(passport));
        bytes32 id1 = reputation.packageId();
        t.packageIds = new bytes32[](2);
        if (id0 < id1) {
            t.packageIds[0] = id0;
            t.packageIds[1] = id1;
        } else {
            t.packageIds[0] = id1;
            t.packageIds[1] = id0;
        }
    }

    /// @dev One side's package data as the kernel forwards it: the inputs and the (mock) proof.
    function _data(IBundleVerifier.BundleInputs memory inputs) internal pure returns (bytes memory) {
        return abi.encode(inputs, abi.encode(true));
    }

    function _sorted3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory out) {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        out = new bytes32[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _sorted4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory out) {
        if (a > b) (a, b) = (b, a);
        if (c > d) (c, d) = (d, c);
        if (a > c) (a, c) = (c, a);
        if (b > d) (b, d) = (d, b);
        if (b > c) (b, c) = (c, b);
        out = new bytes32[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }

    /// @dev The full private set: PASSPORT + REPUTATION + BONDS (§E.3.15.6). The bonds id is the
    ///      vault's own (`vault`, `sink`) pair, which is what the kernel's peer check signs.
    function _bondTerms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.packageIds = _sorted3(
            PackageId.passport(address(passport)),
            PackageId.reputation(address(reputation), FEE_TO, 0, 0, 0, 0),
            PackageId.bonds(address(vault), SINK)
        );
    }

    function _bondMods() internal view returns (PackageMods memory m) {
        m.passport = address(passport);
        m.reputation = address(reputation);
        m.bonds = address(vault);
    }

    function _side(
        address wallet,
        uint256 pk,
        bytes32 subject,
        bytes32 newLeaf,
        bytes32 nullRep,
        bytes32 forDealId,
        uint256 forDeadline
    ) internal view returns (RelayerMock.Side memory s) {
        s.wallet = wallet;
        s.dealSubject = subject;
        s.newLeaf = newLeaf;
        s.nullRep = nullRep;
        s.sideProof = ok(true);
        (pk, forDealId, forDeadline); // the side's consent is its proof now (Anexo R, 2026-09-29)
    }

    /// @dev The bond pieces of one side: the split commitment, its change note and the source note's
    ///      nullifier.
    function _bondSide(
        address wallet,
        uint256 pk,
        bytes32 subject,
        bytes32 newLeaf,
        bytes32 nullRep,
        bytes32 lockCommit,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 forDealId,
        uint256 forDeadline
    ) internal view returns (RelayerMock.Side memory s) {
        s = _side(wallet, pk, subject, newLeaf, nullRep, forDealId, forDeadline);
        s.lockCommit = lockCommit;
        s.changeNote = changeNote;
        s.nullBond = nullBond;
    }

    /// @dev Each side funds one whole note; the split carves the lock out of it in the bundle. The
    ///      holder is re-funded because the deposit would otherwise eat the balance the kernel
    ///      pulls as principal at `activate`.
    function _fundBonds() internal {
        token.mint(holder, PRINCIPAL);
        token.mint(provider, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
        vm.prank(holder);
        vault.deposit(address(token), PRINCIPAL, DEPOSIT_NOTE_H, ok(true));
        vm.prank(provider);
        vault.deposit(address(token), PRINCIPAL, DEPOSIT_NOTE_P, ok(true));
    }

    /// @dev The activation of the bonded deal: both sides' proofs inside `activate`.
    function _activateBonded() internal returns (bytes32) {
        _fundBonds();
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(bondHa);
        bytes memory ps = _signProvider(bondPa);
        RelayerMock.Side memory sideH = _bondSide(
            holder,
            holderPk,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            bondDealId,
            bondHa.deadline
        );
        RelayerMock.Side memory sideP = _bondSide(
            provider,
            providerPk,
            SUBJECT_P,
            ADMIT_LEAF_P,
            NULLREP_P1,
            LOCKCOMMIT_P,
            CHANGE_P,
            NULLBOND_P1,
            bondDealId,
            bondHa.deadline
        );
        return relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            vault,
            bondHa,
            hs,
            bondPa,
            ps,
            ca,
            "",
            bondMods,
            bondDealId,
            sideH,
            sideP,
            PAIR_TAG,
            bundle
        );
    }

    /// @dev The activation, with both sides' proofs inside it (Anexo R, 2026-09-29). All argument
    ///      evaluation is hoisted so no expectation or prank leaks into it.
    function _activate() internal returns (bytes32) {
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        RelayerMock.Side memory sideH =
            _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, dealId, ha.deadline);
        RelayerMock.Side memory sideP =
            _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, dealId, ha.deadline);
        return relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            PrivateBondVault(address(0)), // a PASSPORT+REPUTATION deal: no bond pieces
            ha,
            hs,
            pa,
            ps,
            ca,
            "",
            mods,
            dealId,
            sideH,
            sideP,
            PAIR_TAG,
            bundle
        );
    }

    function _terminalReleased() internal {
        _activate();
        _markFiat(dealId);
        vm.prank(holder); // the controller releases after fiat was marked
        escrow.release(dealId);
    }

    // ---------------------------------------------------------------- activation bundle

    /// What a two-sided private activation costs end to end, and the last gap in EVALUACION.md's
    /// LHF-5. The verifier is mocked here — this suite is about the modules — so the number below is
    /// everything EXCEPT the two proof verifications, and the composition is stated rather than
    /// hidden: add 2 x 745,269 (measured against the committed `prepare_side` fixture in
    /// `BundleVerifier.t.sol`) for the real thing.
    function test_privateActivation_costModel() public {
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        RelayerMock.Side memory sideH =
            _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, dealId, ha.deadline);
        RelayerMock.Side memory sideP =
            _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, dealId, ha.deadline);

        uint256 before = gasleft();
        relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            PrivateBondVault(address(0)),
            ha,
            hs,
            pa,
            ps,
            ca,
            "",
            mods,
            dealId,
            sideH,
            sideP,
            PAIR_TAG,
            bundle
        );
        uint256 everythingElse = before - gasleft();

        emit log_named_uint("two-sided activation, minus verification", everythingElse);
        emit log_named_uint("two real verifications", 2 * 745_269);
        emit log_named_uint("two-sided private activation, composed", everythingElse + 2 * 745_269);
        emit log_named_uint("a Core deal, for comparison", 434_823);
    }

    function test_activate_fullBundle() public {
        bytes32 id = _activate();

        assertEq(id, dealId);
        assertTrue(uint8(escrow.status(dealId)) == uint8(Status.FUNDED));
        (bytes32 subjectH, bytes32 subjectP) = escrow.subjects(dealId);
        assertEq(subjectH, SUBJECT_H);
        assertEq(subjectP, SUBJECT_P);
        // Two leaf0s + the two admit transitions, inserted together by the second admit.
        assertEq(tree.nextIndex(), 4);
        assertTrue(tree.isSpent(NULLREP_H1));
        assertTrue(tree.isSpent(NULLREP_P1));
        // The pair both sides proved is recorded for the claim (§E.3.14.7).
        assertEq(reputation.pairTagOf(dealId), PAIR_TAG);
        assertEq(escrow.postPending(dealId), 0);
    }

    function test_bundle_isAtomic() public {
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);
        providerSig[10] = providerSig[10] ^ 0x01; // break the deal consent
        RelayerMock.Side memory sideH =
            _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, dealId, ha.deadline);
        RelayerMock.Side memory sideP =
            _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, dealId, ha.deadline);
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            PrivateBondVault(address(0)),
            ha,
            hs,
            pa,
            providerSig,
            ca,
            "",
            mods,
            dealId,
            sideH,
            sideP,
            PAIR_TAG,
            bundle
        );
        // A failed activation leaves nothing: no leaves, no nullifiers, no pair.
        assertEq(tree.nextIndex(), 2);
        assertFalse(tree.isSpent(NULLREP_H1));
        assertFalse(tree.isSpent(NULLREP_P1));
        assertEq(reputation.pairTagOf(dealId), bytes32(0));
        assertTrue(uint8(escrow.status(dealId)) == uint8(Status.NONE));
    }

    function test_activate_failsClosedWithoutProofs() public {
        // First deal lands normally.
        _activate();

        // A second deal for the same wallets carries no proofs: there is no buffer left over from the
        // first one to lean on, because there never was one. The activation fails closed.
        HolderAuthorization memory ha2 = _holderAuth(_privateTerms(), 2);
        ProviderAgreement memory pa2 = _providerAuth(_privateTerms(), 2);
        bytes32 deal2 = Consent.dealId(escrow.domainSeparator(), _privateTerms(), 2, 2, 0);
        ControllerAcceptance memory ca;
        bytes memory hs2 = _signHolder(ha2);
        bytes memory ps2 = _signProvider(pa2);
        vm.expectRevert(IPassport.NoPassport.selector);
        escrow.activate(ha2, hs2, pa2, ps2, ca, "", mods);
        assertTrue(uint8(escrow.status(deal2)) == uint8(Status.NONE));
    }

    // ---------------------------------------------------------------- admit

    function test_admit_onlyOperator() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateReputation.Unauthorized.selector);
        reputation.admit(holder, _dealTag(), address(token), PRINCIPAL, address(0), "");
    }

    /// The first side spends its nullifier and parks its leaf; the second spends its own and inserts both.
    function test_admit_spendsAndInsertsBothSidesTogether() public {
        bytes32 root = tree.root();
        bytes memory dataH = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, root, dealId));
        bytes memory dataP = _data(_in(SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, root, dealId));
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.Admitted(holder, SUBJECT_H, address(token), PRINCIPAL);
        vm.prank(address(escrow));
        bytes32 subject = reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), dataH);
        assertEq(subject, SUBJECT_H);
        assertTrue(tree.isSpent(NULLREP_H1));
        assertEq(tree.nextIndex(), 2, "the first side waits for the second");
        vm.prank(address(escrow));
        reputation.admit(provider, dealId, address(token), PRINCIPAL, address(0), dataP);
        assertEq(tree.nextIndex(), 4, "both leaves, together");
        assertEq(reputation.pairTagOf(dealId), PAIR_TAG);
    }

    function test_admit_guards() public {
        bytes32 root = tree.root();
        bytes memory data = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, root, dealId));
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.UnsupportedVault.selector);
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0xB0B), data);
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.SideMismatch.selector);
        reputation.admit(holder, dealId, address(token), PRINCIPAL / 2, address(0), data);
        bytes32 otherDeal = _dealTag();
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.SideMismatch.selector);
        reputation.admit(holder, otherDeal, address(token), PRINCIPAL, address(0), data);
        bytes memory foreignRoot = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, FAKE_ROOT, dealId));
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.UnknownRoot.selector);
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), foreignRoot);
        // Nothing was consumed by the failed admits.
        assertFalse(tree.isSpent(NULLREP_H1));
    }

    /// What an account needs to rebuild its counterparty tree is published with the activation (Anexo R,
    /// 2026-09-29): its hints, under the deal and its subject, so an account finds them from `sk_id` alone.
    function test_admit_publishesTheSidesRecoveryHints() public {
        IBundleVerifier.BundleInputs memory i_ = _in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, tree.root(), dealId);
        i_.hintS = keccak256("the counterparty, padded");
        i_.hintK = keccak256("the pair secret, padded");
        bytes memory data = _data(i_);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.RecoveryHints(dealId, SUBJECT_H, i_.hintS, i_.hintK);
        vm.prank(address(escrow));
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), data);
    }

    /// The two sides of one activation have to name the same pair (§E.3.14.7).
    function test_admit_sidesMustNameOnePair() public {
        bytes32 root = tree.root();
        IBundleVerifier.BundleInputs memory p_ = _in(SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, root, dealId);
        p_.pairTag = keccak256("a counterparty of my own invention");
        bytes memory dataH = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, root, dealId));
        bytes memory dataP = _data(p_);
        vm.prank(address(escrow));
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), dataH);
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.PairMismatch.selector);
        reputation.admit(provider, dealId, address(token), PRINCIPAL, address(0), dataP);
    }

    /// A side the shared verifier never saw proven in this transaction is refused.
    function test_admit_unprovenSideFailsClosed() public {
        bytes32 root = tree.root();
        bytes memory data = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, root, dealId));
        bundle.setAnswer(false);
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.AdmitProofFailed.selector);
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), data);
    }

    /// A bonded proof buys the bond column of the cap; in a deal with no vault nobody reserves its lock.
    function test_admit_unbondedDealRefusesABondedProof() public {
        IBundleVerifier.BundleInputs memory i_ = _in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, tree.root(), dealId);
        i_.lockCommit = LOCKCOMMIT_H;
        bytes memory data = _data(i_);
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.SideMismatch.selector);
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), data);
    }

    /// Anyone may ask the passport to identify a side: it verifies and answers, and leaves nothing behind
    /// but the verifier's transient ticket.
    function test_identify_verifiesAndLeavesNothing() public {
        bytes32 root = tree.root();
        bytes memory data = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, root, dealId));
        assertEq(passport.identify(holder, holder, dealId, data), SUBJECT_H);
        assertEq(tree.nextIndex(), 2);
        assertFalse(tree.isSpent(NULLREP_H1));
        vm.expectRevert(PrivatePassport.DealMismatch.selector);
        passport.identify(holder, holder, _dealTag(), data);
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(holder, holder, dealId, "");
    }

    // ---------------------------------------------------------------- a pool as Holder (D4, 2026-09-29)

    /// A pool has no `sk_id` and cannot prove humanity: its reputation is the pool's, with public stats, and the
    /// official passport identifies an official pool by its address, with no proof. The Provider's side is an
    /// ordinary private side, admitted alone.
    /// A pool acts through its operator (Anexo R, 2026-10-05): its side is never empty. The pool's whole life on the
    /// private stack — the operator's vouch, its ladder, its bond — is `PoolPrivate.t.sol`.
    function test_poolHolder_withoutItsOperator_isRefused() public {
        poolFactory.setOfficial(holder, true); // the Holder wallet stands in for an official pool here
        DealTerms memory t = _privateTerms();
        HolderAuthorization memory ha_ = _holderAuth(t, 7);
        ProviderAgreement memory pa_ = _providerAuth(t, 7);
        bytes32 expected = Consent.dealId(escrow.domainSeparator(), t, 7, 7, 0);
        PackageData memory data;
        data.provider = _data(_in(SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, tree.root(), expected));
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha_);
        bytes memory ps = _signProvider(pa_);
        vm.expectRevert(PrivatePassport.OperatorRequired.selector);
        escrow.activate(ha_, hs, pa_, ps, ca, "", mods, data);
    }

    function test_aWalletThatIsNoOfficialPool_hasNoProoflessIdentity() public {
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(holder, holder, dealId, "");
    }

    // ---------------------------------------------------------------- terminal

    function test_terminal_pendsBothDeltas() public {
        _terminalReleased();
        assertTrue(uint8(escrow.status(dealId)) == uint8(Status.RELEASED));
        assertEq(escrow.postPending(dealId), 0); // both notifications landed on first attempt

        (IReputation.Close kindH, address tokenH, uint256 principalH) = reputation.pending(SUBJECT_H);
        assertTrue(kindH == IReputation.Close.Peaceful);
        assertEq(tokenH, address(token));
        assertEq(principalH, PRINCIPAL);
        (IReputation.Close kindP, address tokenP, uint256 principalP) = reputation.pending(SUBJECT_P);
        assertTrue(kindP == IReputation.Close.Peaceful);
        assertEq(tokenP, address(token));
        assertEq(principalP, PRINCIPAL);
        assertFalse(reputation.claimed(SUBJECT_H));
        assertFalse(reputation.claimed(SUBJECT_P));
    }

    function test_notifyTerminal_onlyOperator() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(PrivateReputation.Unauthorized.selector);
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), PRINCIPAL, IReputation.Close.Peaceful);
    }

    function test_notifyTerminal_doublePendingFailsClosed() public {
        vm.prank(address(escrow));
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), PRINCIPAL, IReputation.Close.Peaceful);
        // Same subject twice: the same human on both ends of a deal is pathological, and the
        // module fails closed rather than overwrite a delta (the account punishes itself).
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.AlreadyPending.selector);
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), PRINCIPAL, IReputation.Close.Silent);
    }

    function test_notifyTerminal_afterClaimFailsClosed() public {
        // Through the real activation, because the claim now needs the deal's pair tag — the module
        // will not hand out a credit for a counterparty no activation ever recorded (§E.3.14.7).
        _terminalReleased();
        bytes32 root = tree.root();
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.AlreadyClaimed.selector);
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), PRINCIPAL, IReputation.Close.Silent);
    }

    /// A claim for a deal nobody ever activated has no pair behind it, so there is no counterparty to
    /// ask credit for. Fail-closed: the module refuses rather than crediting an unnamed partner.
    function test_claim_withoutAnActivationHasNoPair() public {
        vm.prank(address(escrow));
        reputation.notifyTerminal(SUBJECT_H, _cpTag(), address(token), PRINCIPAL, IReputation.Close.Peaceful);
        bytes32 root = tree.root();
        bytes memory proof = ok(true);
        vm.expectRevert(PrivateReputation.NoPair.selector);
        reputation.claim(keccak256("a deal that never happened"), SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, proof);
    }

    // ---------------------------------------------------------------- claim

    function test_claim_appliesDeltaOnce() public {
        _terminalReleased();
        uint256 before = tree.nextIndex();
        bytes32 root = tree.root();

        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
        assertTrue(reputation.claimed(SUBJECT_H));
        assertTrue(tree.isSpent(NULLREP_H2));
        assertEq(tree.nextIndex(), before + 1);
        (IReputation.Close kind, address pendingToken, uint256 pendingPrincipal) = reputation.pending(SUBJECT_H);
        assertTrue(kind == IReputation.Close.Peaceful);
        assertEq(pendingToken, address(0));
        assertEq(pendingPrincipal, 0);

        vm.expectRevert(PrivateReputation.AlreadyClaimed.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
    }

    function test_claim_requiresTerminalDelta() public {
        _activate(); // live deal, no terminal yet
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.NothingToClaim.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
    }

    function test_claim_unknownSubject() public {
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.NothingToClaim.selector);
        reputation.claim(dealId, keccak256("no-such-subject"), CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
    }

    function test_claim_badProofIsAtomic() public {
        _terminalReleased();
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.ClaimProofFailed.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(false));
        assertFalse(reputation.claimed(SUBJECT_H));
        assertFalse(tree.isSpent(NULLREP_H2));
        (, address pendingToken, uint256 pendingPrincipal) = reputation.pending(SUBJECT_H);
        assertEq(pendingToken, address(token));
        assertEq(pendingPrincipal, PRINCIPAL);
    }

    function test_claim_unknownRoot() public {
        _terminalReleased();
        vm.expectRevert(PrivateReputation.UnknownRoot.selector);
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, FAKE_ROOT, ok(true));
    }

    // ---------------------------------------------------------------- bonds deal (F3, §E.3.15.6)

    function test_admit_acceptsTheBoundVault() public {
        IBundleVerifier.BundleInputs memory i_ = _in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, tree.root(), dealId);
        i_.lockCommit = LOCKCOMMIT_H;
        bytes memory data = _data(i_);
        vm.prank(address(escrow));
        bytes32 subject = reputation.admit(holder, dealId, address(token), PRINCIPAL, address(vault), data);
        assertEq(subject, SUBJECT_H, "the bound vault is the one vault this reputation admits");
    }

    function test_admit_rejectsForeignVault() public {
        IBundleVerifier.BundleInputs memory i_ = _in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, tree.root(), dealId);
        i_.lockCommit = LOCKCOMMIT_H;
        bytes memory data = _data(i_);
        // A counterparty signs a BONDS deal trusting that the lock exists: a foreign vault under
        // the same reputation would fake that protection, so the binding refuses it.
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.UnsupportedVault.selector);
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0xB0B), data);
    }

    function test_bondDeal_fullBundle() public {
        bytes32 id = _activateBonded();

        assertEq(id, bondDealId);
        assertTrue(uint8(escrow.status(bondDealId)) == uint8(Status.FUNDED));
        // Both lock records: the §E.3.14.5 lock each, with the split commitments inside.
        (address lockTokenH, uint256 lockAmountH, bytes32 lockCommitH, bool releasedH) =
            vault.lockOf(bondDealId, SUBJECT_H);
        assertEq(lockTokenH, address(token));
        assertEq(lockAmountH, LOCK);
        assertEq(lockCommitH, LOCKCOMMIT_H);
        assertFalse(releasedH);
        (, uint256 lockAmountP, bytes32 lockCommitP,) = vault.lockOf(bondDealId, SUBJECT_P);
        assertEq(lockAmountP, LOCK);
        assertEq(lockCommitP, LOCKCOMMIT_P);
        // The notes tree holds both deposits and both change notes.
        assertEq(vault.notesTree().nextIndex(), 4);
        assertTrue(vault.notesTree().isSpent(NULLBOND_H1));
        assertTrue(vault.notesTree().isSpent(NULLBOND_P1));
    }

    function test_bondDeal_bundleIsAtomic() public {
        _fundBonds();
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(bondHa);
        bytes memory ps = _signProvider(bondPa);
        ps[10] = ps[10] ^ 0x01; // break the deal consent
        RelayerMock.Side memory sideH = _bondSide(
            holder,
            holderPk,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            bondDealId,
            bondHa.deadline
        );
        RelayerMock.Side memory sideP = _bondSide(
            provider,
            providerPk,
            SUBJECT_P,
            ADMIT_LEAF_P,
            NULLREP_P1,
            LOCKCOMMIT_P,
            CHANGE_P,
            NULLBOND_P1,
            bondDealId,
            bondHa.deadline
        );
        vm.expectRevert(Escrow.InvalidProviderSignature.selector);
        relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            vault,
            bondHa,
            hs,
            bondPa,
            ps,
            ca,
            "",
            bondMods,
            bondDealId,
            sideH,
            sideP,
            PAIR_TAG,
            bundle
        );
        // The deposits predate the activation and survive it; the splits did not land.
        assertEq(vault.notesTree().nextIndex(), 2);
        assertFalse(vault.notesTree().isSpent(NULLBOND_H1));
        assertFalse(vault.notesTree().isSpent(NULLBOND_P1));
        (, uint256 lockAmountH,,) = vault.lockOf(bondDealId, SUBJECT_H);
        assertEq(lockAmountH, 0);
        assertTrue(uint8(escrow.status(bondDealId)) == uint8(Status.NONE));
    }

    function test_bondDeal_peacefulThenClaimThenReabsorb() public {
        _activateBonded();
        _markFiat(bondDealId);
        vm.prank(holder); // the controller releases after fiat was marked
        escrow.release(bondDealId);
        assertEq(escrow.postPending(bondDealId), 0, "notifications and unlocks all landed");

        (,, bytes32 lockCommitH, bool releasedH) = vault.lockOf(bondDealId, SUBJECT_H);
        assertTrue(releasedH, "kernel unlock did not release the holder lock");
        assertEq(lockCommitH, LOCKCOMMIT_H);
        // Gating: the lock does not come back before the terminal delta is claimed.
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(bondDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));

        // Claim the delta, then the lock merges into a fresh note — exactly once.
        reputation.claim(bondDealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, tree.root(), ok(true));
        uint256 notesBefore = vault.notesTree().nextIndex();
        vault.reabsorb(bondDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        assertEq(vault.notesTree().nextIndex(), notesBefore + 1, "reabsorb did not merge a note");
        assertTrue(vault.notesTree().isSpent(NULLBOND_H2));
        (, uint256 lockAmountH,,) = vault.lockOf(bondDealId, SUBJECT_H);
        assertEq(lockAmountH, 0, "reabsorbed lock still on the books");
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(bondDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));

        // The provider side is still gated: no claim, no reabsorb.
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(bondDealId, SUBJECT_P, bytes32(uint256(0x2202)), keccak256("nullbond-p-2"), ok(true));
    }

    /// The kernel's `burn` under a deadlock (Anexo R, 2026-09-24): a deal with bonds but no tribunal, a
    /// fight nobody settled. Both locks leave the private vault for the sink — the same disposal the
    /// public vault runs, answered here by the private one — and nothing is left to reabsorb.
    function test_bondDeal_deadlockBurnsBothLocks() public {
        _activateBonded();
        _markFiat(bondDealId);
        _openDisputed(bondDealId);
        vm.warp(block.timestamp + 7200 + 1); // disputeDuration of the p2p terms
        escrow.forceDisputeTimeout(bondDealId);

        assertTrue(uint8(escrow.status(bondDealId)) == uint8(Status.STALEMATE));
        assertEq(escrow.postPending(bondDealId), 0);
        // The private vault's sink is the same dead address the kernel burns the principal to.
        assertEq(token.balanceOf(SINK), PRINCIPAL + 2 * LOCK, "principal and both locks burned, to nobody");
        (, uint256 amountH,,) = vault.lockOf(bondDealId, SUBJECT_H);
        (, uint256 amountP,,) = vault.lockOf(bondDealId, SUBJECT_P);
        assertEq(amountH, 0, "consumed, not released: there is nothing to reabsorb");
        assertEq(amountP, 0);
    }

    /// @dev The last kernel verb the private vault had never answered under fire: `slash`, driven
    ///      by a ruling, from a court paid in ETH at opening. Ruling 1 = HolderWins: the kernel slashes (subjectP, subjectH, ...,
    ///      t.holder) — the provider's lock to the holder's signing address, the holder's own lock
    ///      released for a claim-gated reabsorb.
    function test_bondDeal_ruledSlashThroughCourt() public {
        EthCourtMock court = new EthCourtMock(0.01 ether, address(escrow), 0, address(0xFEE));
        vm.deal(holder, 1 ether);

        // The bonded deal, now with arbitration: four sorted ids and a ruling clock.
        DealTerms memory t = _bondTerms();
        t.packageIds = _sorted4(
            PackageId.passport(address(passport)),
            PackageId.reputation(address(reputation), FEE_TO, 0, 0, 0, 0),
            PackageId.bonds(address(vault), SINK),
            court.packageId()
        );
        t.arbitrationDuration = 1 days;
        HolderAuthorization memory courtHa = _holderAuth(t, 1);
        ProviderAgreement memory courtPa = _providerAuth(t, 1);
        PackageMods memory courtMods = _bondMods();
        courtMods.court = address(court);
        bytes32 courtDealId = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);

        _fundBonds();
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(courtHa);
        bytes memory ps = _signProvider(courtPa);
        RelayerMock.Side memory sideH = _bondSide(
            holder,
            holderPk,
            SUBJECT_H,
            ADMIT_LEAF_H,
            NULLREP_H1,
            LOCKCOMMIT_H,
            CHANGE_H,
            NULLBOND_H1,
            courtDealId,
            courtHa.deadline
        );
        RelayerMock.Side memory sideP = _bondSide(
            provider,
            providerPk,
            SUBJECT_P,
            ADMIT_LEAF_P,
            NULLREP_P1,
            LOCKCOMMIT_P,
            CHANGE_P,
            NULLBOND_P1,
            courtDealId,
            courtPa.deadline
        );
        bytes32 id = relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            vault,
            courtHa,
            hs,
            courtPa,
            ps,
            ca,
            "",
            courtMods,
            courtDealId,
            sideH,
            sideP,
            PAIR_TAG,
            bundle
        );
        assertEq(id, courtDealId);

        _markFiat(courtDealId);
        vm.prank(holder);
        escrow.openCourt{value: 0.01 ether}(courtDealId);
        assertTrue(uint8(escrow.status(courtDealId)) == uint8(Status.ARBITRATION_ACTIVE));
        court.giveRuling(courtDealId, 1); // the court rules for the holder
        escrow.readRuling(courtDealId);

        assertTrue(uint8(escrow.status(courtDealId)) == uint8(Status.RESOLVED_BY_ARBITRATION));
        assertEq(escrow.postPending(courtDealId), 0, "notifications and the slash all landed");
        // Principal refund + the provider's lock, both to the holder's signing address.
        assertEq(token.balanceOf(holder), PRINCIPAL + LOCK);
        assertEq(token.balanceOf(provider), 0);
        // The loser's record is consumed; the winner's own lock is released, not taken.
        (, uint256 loserAmount,,) = vault.lockOf(courtDealId, SUBJECT_P);
        assertEq(loserAmount, 0, "the loser's lock was not consumed");
        (,, bytes32 winnerCommit, bool winnerReleased) = vault.lockOf(courtDealId, SUBJECT_H);
        assertTrue(winnerReleased, "the winner's own lock was not released");
        assertEq(winnerCommit, LOCKCOMMIT_H);
        // Both terminal deltas pended: ArbWin for the holder, ArbLoss for the provider.
        (IReputation.Close kindH,,) = reputation.pending(SUBJECT_H);
        assertTrue(kindH == IReputation.Close.ArbWin);
        (IReputation.Close kindP,,) = reputation.pending(SUBJECT_P);
        assertTrue(kindP == IReputation.Close.ArbLoss);
        // The winner still gates on the claim: ruling is not completion.
        vm.expectRevert(PrivateBondVault.ClaimRequired.selector);
        vault.reabsorb(courtDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        reputation.claim(courtDealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, tree.root(), ok(true));
        vault.reabsorb(courtDealId, SUBJECT_H, REABSORB_NOTE_H, NULLBOND_H2, ok(true));
        (, uint256 winnerAmount,,) = vault.lockOf(courtDealId, SUBJECT_H);
        assertEq(winnerAmount, 0, "the winner's reabsorb did not clear the record");
        // The loser never reabsorbs: the record is gone.
        vm.expectRevert(PrivateBondVault.NoLock.selector);
        vault.reabsorb(courtDealId, SUBJECT_P, bytes32(uint256(0x2202)), keccak256("nullbond-p-2"), ok(true));
    }

    // ---------------------------------------------------------------- open accounts (2026-10-01)

    bytes32 internal constant OPEN_LEAF0 = bytes32(uint256(0x1003));
    bytes32 internal constant HN_LATE = keccak256("human-late");
    bytes32 internal constant UPGRADED_LEAF = bytes32(uint256(0x1004));
    bytes32 internal constant NULLREP_OPEN0 = keccak256("nullrep-open-0");

    /// The activation with either side open: the same relayer path, the sides' flags as given.
    function _activateWith(bool openH, bool openP) internal returns (bytes32) {
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        RelayerMock.Side memory sideH =
            _side(holder, holderPk, SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, dealId, ha.deadline);
        RelayerMock.Side memory sideP =
            _side(provider, providerPk, SUBJECT_P, ADMIT_LEAF_P, NULLREP_P1, dealId, ha.deadline);
        sideH.open = openH;
        sideP.open = openP;
        return relayer.activatePrivate(
            escrow,
            passport,
            reputation,
            PrivateBondVault(address(0)),
            ha,
            hs,
            pa,
            ps,
            ca,
            "",
            mods,
            dealId,
            sideH,
            sideP,
            PAIR_TAG,
            bundle
        );
    }

    function test_registerOpen_insertsAGenesisWithNoHuman() public {
        uint256 before = tree.nextIndex();
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.OpenAccountRegistered(OPEN_LEAF0, before);
        reputation.registerOpen(ok(true), OPEN_LEAF0);
        assertEq(tree.nextIndex(), before + 1);
        // No human, so nothing to burn and nothing to mark — and nothing stops a second open account.
        reputation.registerOpen(ok(true), bytes32(uint256(0x1005)));
        assertEq(tree.nextIndex(), before + 2);
    }

    function test_registerOpen_needsItsProof() public {
        uint256 before = tree.nextIndex();
        vm.expectRevert(PrivateReputation.AccountNotVerified.selector);
        reputation.registerOpen(ok(false), OPEN_LEAF0);
        assertEq(tree.nextIndex(), before, "nothing inserted");
    }

    /// The four shapes of a two-sided deal: it credits only when both sides are verified.
    function test_aDealCredits_onlyBetweenTwoVerifiedSides() public {
        bytes32 root = tree.root();
        bool[2][4] memory shapes = [[false, false], [true, false], [false, true], [true, true]];
        for (uint256 k; k < 4; k++) {
            bytes32 id = keccak256(abi.encode("shape", k));
            IBundleVerifier.BundleInputs memory h_ =
                _in(SUBJECT_H, ADMIT_LEAF_H, keccak256(abi.encode("nh", k)), root, id);
            IBundleVerifier.BundleInputs memory p_ =
                _in(SUBJECT_P, ADMIT_LEAF_P, keccak256(abi.encode("np", k)), root, id);
            h_.verified = !shapes[k][0];
            p_.verified = !shapes[k][1];
            bytes memory dataH = _data(h_);
            bytes memory dataP = _data(p_);
            vm.prank(address(escrow));
            reputation.admit(holder, id, address(token), PRINCIPAL, address(0), dataH);
            vm.prank(address(escrow));
            reputation.admit(provider, id, address(token), PRINCIPAL, address(0), dataP);
            assertEq(reputation.creditable(id), k == 0, "credit iff neither side is open");
        }
    }

    /// The same rule as a fuzz over the two flags, against the module's own record.
    function testFuzz_creditableIsBothVerified(bool vH, bool vP, bytes32 id) public {
        vm.assume(id != bytes32(0));
        bytes32 root = tree.root();
        IBundleVerifier.BundleInputs memory h_ = _in(SUBJECT_H, ADMIT_LEAF_H, keccak256(abi.encode("nh", id)), root, id);
        IBundleVerifier.BundleInputs memory p_ = _in(SUBJECT_P, ADMIT_LEAF_P, keccak256(abi.encode("np", id)), root, id);
        h_.verified = vH;
        p_.verified = vP;
        bytes memory dataH = _data(h_);
        bytes memory dataP = _data(p_);
        vm.prank(address(escrow));
        reputation.admit(holder, id, address(token), PRINCIPAL, address(0), dataH);
        vm.prank(address(escrow));
        reputation.admit(provider, id, address(token), PRINCIPAL, address(0), dataP);
        assertEq(reputation.creditable(id), vH && vP);
    }

    /// A lone first side decides nothing: the word is written when the second side arrives, never before.
    function test_aLoneSide_writesNoCredit() public {
        bytes memory dataH = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, tree.root(), dealId));
        vm.prank(address(escrow));
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), dataH);
        assertFalse(reputation.creditable(dealId));
    }

    /// An open side has no bond column: the module refuses it even if a verifier let a bonded open side through.
    function test_anOpenSide_cannotCarryABond() public {
        IBundleVerifier.BundleInputs memory i_ = _in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_H1, tree.root(), bondDealId);
        i_.lockCommit = LOCKCOMMIT_H;
        i_.verified = false;
        bytes memory data = _data(i_);
        vm.prank(address(escrow));
        vm.expectRevert(PrivateReputation.BondsNeedPassport.selector);
        reputation.admit(holder, bondDealId, address(token), PRINCIPAL, address(vault), data);
        assertFalse(tree.isSpent(NULLREP_H1), "nothing consumed");
    }

    /// Through the kernel: a deal with an open Provider activates, releases, and pends a Peaceful close for both —
    /// the record of both takes it — and each claim hands the verifier `credit = false`.
    function test_aMixedDeal_recordsBothSides_andCreditsNeither() public {
        _activateWith(false, true);
        assertFalse(reputation.creditable(dealId), "an open side: no credit");
        _markFiat(dealId);
        vm.prank(holder);
        escrow.release(dealId);
        (IReputation.Close kindH,,) = reputation.pending(SUBJECT_H);
        (IReputation.Close kindP,,) = reputation.pending(SUBJECT_P);
        assertTrue(kindH == IReputation.Close.Peaceful && kindP == IReputation.Close.Peaceful, "both records");

        bytes32 root = tree.root();
        vm.expectCall(
            address(claimProof),
            abi.encodeCall(
                IClaimVerifier.verifyClaim,
                (
                    dealId,
                    SUBJECT_H,
                    CLAIM_LEAF_H,
                    NULLREP_H2,
                    IReputation.Close.Peaceful,
                    address(token),
                    PRINCIPAL,
                    root,
                    PAIR_TAG,
                    block.timestamp / 1 days,
                    false,
                    ok(true)
                )
            )
        );
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
        // The other side's claim reads the same word later: it is never cleared.
        assertFalse(reputation.creditable(dealId));
    }

    /// And the verified deal hands it `credit = true`, for both sides' claims.
    function test_aVerifiedDeal_handsTheClaimItsCredit() public {
        _activate();
        assertTrue(reputation.creditable(dealId));
        _markFiat(dealId);
        vm.prank(holder);
        escrow.release(dealId);
        bytes32 root = tree.root();
        vm.expectCall(
            address(claimProof),
            abi.encodeCall(
                IClaimVerifier.verifyClaim,
                (
                    dealId,
                    SUBJECT_H,
                    CLAIM_LEAF_H,
                    NULLREP_H2,
                    IReputation.Close.Peaceful,
                    address(token),
                    PRINCIPAL,
                    root,
                    PAIR_TAG,
                    block.timestamp / 1 days,
                    true,
                    ok(true)
                )
            )
        );
        reputation.claim(dealId, SUBJECT_H, CLAIM_LEAF_H, NULLREP_H2, root, ok(true));
        assertTrue(reputation.creditable(dealId), "still there for the Provider's claim");
    }

    /// Penalties ignore the flag: an open Provider who lets the fiat clock run out is marked like anyone else.
    function test_anOpenSide_isPenalisedLikeAnyOther() public {
        _activateWith(false, true);
        vm.warp(block.timestamp + 3600);
        escrow.timeoutFiat(dealId);
        (IReputation.Close kindP,,) = reputation.pending(SUBJECT_P);
        assertTrue(kindP == IReputation.Close.NoShow, "the penalty pends for the open side");
    }

    // --- the upgrade ------------------------------------------------------------------------------------

    function test_upgrade_verifiesInPlace() public {
        reputation.registerOpen(ok(true), OPEN_LEAF0);
        bytes32 root = tree.root();
        passport.register(ok(true), HN_LATE);
        uint256 index = tree.nextIndex();
        vm.expectEmit(true, true, true, true, address(reputation));
        emit PrivateReputation.AccountVerified(HN_LATE, UPGRADED_LEAF, index);
        reputation.upgrade(ok(true), HN_LATE, root, NULLREP_OPEN0, UPGRADED_LEAF);
        assertTrue(reputation.registeredHn(HN_LATE), "the human's one slot");
        assertTrue(tree.isSpent(NULLREP_OPEN0), "the open version is spent");
        assertEq(tree.nextIndex(), index + 1, "the flagged leaf is in");
    }

    function test_upgrade_needsTheHumanityBurnedFirst() public {
        reputation.registerOpen(ok(true), OPEN_LEAF0);
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.HumanityNotProven.selector);
        reputation.upgrade(ok(true), HN_LATE, root, NULLREP_OPEN0, UPGRADED_LEAF);
    }

    /// A human who registered verified spent the slot an upgrade needs, and the other way round.
    function test_upgrade_isOnePerHuman() public {
        reputation.registerOpen(ok(true), OPEN_LEAF0);
        bytes32 root = tree.root();
        vm.expectRevert(PrivateReputation.AlreadyRegistered.selector);
        reputation.upgrade(ok(true), HN_H, root, NULLREP_OPEN0, UPGRADED_LEAF); // HN_H registered in setUp

        passport.register(ok(true), HN_LATE);
        reputation.upgrade(ok(true), HN_LATE, root, NULLREP_OPEN0, UPGRADED_LEAF);
        vm.expectRevert(PrivateReputation.AlreadyRegistered.selector);
        reputation.register(ok(true), HN_LATE, bytes32(uint256(0x1006)));
    }

    function test_upgrade_needsALiveRootAndAProof_andIsAtomic() public {
        reputation.registerOpen(ok(true), OPEN_LEAF0);
        bytes32 root = tree.root();
        passport.register(ok(true), HN_LATE);
        vm.expectRevert(PrivateReputation.UnknownRoot.selector);
        reputation.upgrade(ok(true), HN_LATE, FAKE_ROOT, NULLREP_OPEN0, UPGRADED_LEAF);
        vm.expectRevert(PrivateReputation.AccountNotVerified.selector);
        reputation.upgrade(ok(false), HN_LATE, root, NULLREP_OPEN0, UPGRADED_LEAF);
        assertFalse(reputation.registeredHn(HN_LATE), "nothing marked");
        assertFalse(tree.isSpent(NULLREP_OPEN0), "nothing spent");
    }

    /// The upgrade is a version transition like any other: a version already spent by an activation cannot be
    /// upgraded, and the account has to prove its CURRENT leaf.
    function test_upgrade_serializesOnTheVersionNullifier() public {
        reputation.registerOpen(ok(true), OPEN_LEAF0);
        bytes32 root = tree.root();
        passport.register(ok(true), HN_LATE);
        bytes memory dataH = _data(_in(SUBJECT_H, ADMIT_LEAF_H, NULLREP_OPEN0, root, dealId));
        vm.prank(address(escrow));
        reputation.admit(holder, dealId, address(token), PRINCIPAL, address(0), dataH);
        vm.expectRevert(PoseidonTree.NullifierUsed.selector);
        reputation.upgrade(ok(true), HN_LATE, root, NULLREP_OPEN0, UPGRADED_LEAF);
    }
}

/// @dev The factory's one question, answered on demand.
contract PoolFactoryStub {
    mapping(address => bool) public isOfficial;

    function setOfficial(address pool, bool on) external {
        isOfficial[pool] = on;
    }
}
