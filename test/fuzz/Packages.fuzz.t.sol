// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualSplit,
    CoSignedRelease,
    PackageMods
} from "../../src/libraries/Types.sol";
import {Consent} from "../../src/libraries/Consent.sol";
import {PackageId} from "../../src/libraries/PackageId.sol";
import {Escrow} from "../../src/Escrow.sol";
import {Packages} from "../../src/libraries/Packages.sol";
import {TestToken} from "../../mocks/TestToken.sol";
import {PassportMock} from "../../mocks/PassportMock.sol";
import {BpsReputation} from "../ProportionalFees.t.sol";
import {Reputation} from "../../mocks/Reputation.sol";
import {BondVault} from "../../mocks/BondVault.sol";
import {PaymentProof} from "../../src/packages/PaymentProof.sol";
import {IPaymentVerifier} from "../../src/packages/interfaces/IPaymentVerifier.sol";
import {PaymentVerifierMock} from "../../mocks/PaymentVerifierMock.sol";
import {IReputation} from "../../src/packages/interfaces/IReputation.sol";

/// @dev Property tests over the extension surface: KERNEL-04 (fees never block a terminal), fee arithmetic,
///      Reputation score/cap formulas, BondVault lock/slash/burn rules, and packageId binding.
contract PackagesFuzzTest is Test {
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
    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant PROVIDER_PK = 0xB0B;
    uint256 internal constant T1_CAP = 250e6; // 6-dec token, score 0, no bond
    bytes32 internal constant SUB_H = keccak256("human-h");
    bytes32 internal constant SUB_P = keccak256("human-p");
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant SINK = address(0xdEaD);

    Escrow internal escrow;
    TestToken internal token;
    PassportMock internal passport;
    address internal holder;
    address internal provider;

    function setUp() public {
        holder = vm.addr(HOLDER_PK);
        provider = vm.addr(PROVIDER_PK);
        token = new TestToken();
        escrow = new Escrow(address(0), 0, 0);
        passport = new PassportMock();
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
    }

    // --- KERNEL-04: a fee that does not fit is skipped, the terminal always commits -------------------

    /// completionBps over the whole uint256 range, including shares no honest module would declare: release /
    /// co-signed release / split all commit; the share is charged iff it fits (KERNEL-04).
    function testFuzz_completionFee_neverBlocksTerminal(
        uint256 principal,
        uint256 completionBps,
        uint16 bps,
        uint8 path
    ) public {
        principal = bound(principal, 1, T1_CAP);
        bps = uint16(bound(bps, 0, 10_000));
        path = uint8(bound(path, 0, 2));
        BpsReputation rep = new BpsReputation(passport, FEE_RECIPIENT, 0, completionBps, address(escrow));
        uint256 completionFee = Packages.share(principal, completionBps);

        bytes32 id = _activateWithRep(rep, principal);
        vm.prank(provider);
        escrow.markFiat(id);

        if (path == 0) {
            vm.prank(holder);
            escrow.release(id);
        } else if (path == 1) {
            _coSignedRelease(id);
        } else {
            _mutualSplit(id, bps);
        }

        (Status s, uint256 h, uint256 p) = escrow.settlementOf(id);
        // Invoiced iff the Provider's share is non-zero and the fee fits; a split that rounds the Provider
        // to zero is a refund and is never invoiced. "Fits" is strict -- `_invoice` skips at `fee >= left`,
        // so a fee equal to the whole pot is not collected and the winner keeps it all.
        bool providerPaid = path != 2 || principal * bps / 10_000 != 0;
        uint256 expectedFee = providerPaid && completionFee < principal ? completionFee : 0;
        uint256 left = principal - expectedFee;
        assertEq(token.balanceOf(FEE_RECIPIENT), expectedFee, "fee != hashed completion fee (or 0 if it does not fit)");
        assertEq(h + p + expectedFee, principal, "fee + payouts != principal");
        if (path == 2) {
            assertEq(uint8(s), uint8(Status.RESOLVED_SPLIT));
            assertEq(p, left * bps / 10_000, "split bps applied before the fee");
        } else {
            assertEq(uint8(s), uint8(Status.RELEASED));
            assertEq(p, left);
        }
    }

    /// ZK: verifyFee first, completion second, each skipped independently if it does not fit. Never a revert.
    function testFuzz_zkFee_thenCompletion_neverBlocksRelease(
        uint256 principal,
        uint256 verifyFee,
        uint256 completionBps
    ) public {
        principal = bound(principal, 1, T1_CAP);
        verifyFee = bound(verifyFee, 0, type(uint256).max >> 1);
        BpsReputation rep = new BpsReputation(passport, FEE_RECIPIENT, 0, completionBps, address(escrow));
        uint256 completionFee = Packages.share(principal, completionBps);
        PaymentProof zk =
            new PaymentProof(address(escrow), new PaymentVerifierMock(), FEE_RECIPIENT, verifyFee, address(0));

        DealTerms memory t = _terms(principal);
        t.packageIds = _sorted3(passport.packageId(), rep.packageId(), zk.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(rep);
        mods.zk = address(zk);
        token.mint(holder, principal);
        bytes32 id = _activate(t, mods);

        escrow.verifyProof(
            id,
            abi.encode(
                IPaymentVerifier.PaymentClaim({
                    dealId: id,
                    fiatCommit: t.fiatCommit,
                    notBefore: uint64(escrow.clocks(id).activatedAt),
                    holder: t.holder
                }),
                keccak256("receipt")
            )
        );

        // Mirrors `_invoice`, which skips at `fee >= left`: a fee equal to the remaining pot does not fit and
        // is not collected, so the winner keeps it all. The comparison here must stay strict in lockstep.
        uint256 left = principal;
        uint256 fees;
        if (verifyFee != 0 && verifyFee < left) {
            left -= verifyFee;
            fees += verifyFee;
        }
        if (completionFee != 0 && completionFee < left) {
            left -= completionFee;
            fees += completionFee;
        }
        (Status s, uint256 h, uint256 p) = escrow.settlementOf(id);
        assertEq(uint8(s), uint8(Status.RELEASED));
        assertEq(h, 0);
        assertEq(p, left, "provider != principal - fees that fit");
        assertEq(token.balanceOf(FEE_RECIPIENT), fees, "fee recipient != fees that fit");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    /// Activation fee is extra to principal and fails closed: without it there is no deal and no nonce burn.
    function testFuzz_activationFee_isExtraAndAtomic(uint256 principal, uint256 activationBps, bool fund) public {
        principal = bound(principal, 10_000, T1_CAP); // a share of at least one base unit at 1 bps
        activationBps = bound(activationBps, 1, 10_000);
        Reputation rep = new Reputation(passport, FEE_RECIPIENT, activationBps, 0, 0, 0, address(escrow));
        uint256 activationFee = Packages.share(principal, activationBps);
        DealTerms memory t = _terms(principal);
        t.packageIds = _sorted2(passport.packageId(), rep.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(rep);
        token.mint(holder, fund ? principal + activationFee : principal + activationFee - 1);

        HolderAuthorization memory ha = HolderAuthorization({terms: t, nonce: 1, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa = ProviderAgreement({terms: t, nonce: 1, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;
        bytes memory hs = _sign(HOLDER_PK, Consent.hashHolderAuthorization(ha));
        bytes memory ps = _sign(PROVIDER_PK, Consent.hashProviderAgreement(pa));
        if (!fund) {
            vm.expectRevert();
            escrow.activate(ha, hs, pa, ps, ca, "", mods);
            assertFalse(escrow.used(holder, 1), "nonce burned by a failed activation");
            assertEq(token.balanceOf(FEE_RECIPIENT), 0, "fee charged without a deal");
            assertEq(rep.inFlight(SUB_H, address(token)), 0, "inFlight written without a deal");
            return;
        }
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
        assertEq(token.balanceOf(FEE_RECIPIENT), activationFee);
        assertEq(token.balanceOf(address(escrow)), principal, "escrow holds more than principal");
        assertEq(token.balanceOf(holder), 0);
    }

    // --- Reputation: score, tiers, cap ---------------------------------------------------------------

    /// score = count + volume/UNIT - penalty (saturating); cap follows the tier table and is monotone in score.
    function testFuzz_reputation_scoreAndCap(uint8 peaceful, uint8 stalemates, uint8 losses, uint256 principal) public {
        peaceful = uint8(bound(peaceful, 0, 12));
        stalemates = uint8(bound(stalemates, 0, 4));
        losses = uint8(bound(losses, 0, 2));
        Reputation rep = new Reputation(passport, FEE_RECIPIENT, 0, 0, 0, 0, address(this));
        uint256 unit = 250e6;
        uint256 volume;
        for (uint256 i; i < peaceful; i++) {
            uint256 cap = rep.cap(SUB_H, address(token), false);
            uint256 p = bound(uint256(keccak256(abi.encode(principal, i))), 1, cap < 5000e6 ? cap : 5000e6);
            rep.admit(holder, _dealTag(), address(token), p, address(0), "");
            rep.notifyTerminal(SUB_H, _cpTag(), address(token), p, IReputation.Close.Peaceful);
            volume += p;
        }
        for (uint256 i; i < stalemates; i++) {
            rep.admit(holder, _dealTag(), address(token), 1, address(0), "");
            rep.notifyTerminal(SUB_H, _cpTag(), address(token), 1, IReputation.Close.Stalemate);
        }
        for (uint256 i; i < losses; i++) {
            rep.admit(holder, _dealTag(), address(token), 1, address(0), "");
            rep.notifyTerminal(SUB_H, _cpTag(), address(token), 1, IReputation.Close.ArbLoss);
        }
        uint256 raw = uint256(peaceful) + volume / unit;
        uint256 penalty = uint256(stalemates) * 5 + uint256(losses) * 15;
        uint256 expected = raw > penalty ? raw - penalty : 0;
        assertEq(rep.score(SUB_H, address(token)), expected, "score formula");
        assertEq(rep.inFlight(SUB_H, address(token)), 0, "inFlight not released");

        uint256 base = rep.cap(SUB_H, address(token), false);
        uint256 bonded = rep.cap(SUB_H, address(token), true);
        assertGe(bonded, base, "bond column below base");
        (uint256 eb, uint256 ebb) = _tier(expected);
        assertEq(base, eb, "base cap tier");
        assertEq(bonded, ebb, "bonded cap tier");
    }

    /// admit rejects exactly when inFlight + principal > cap; silence and cancel never move the score.
    function testFuzz_reputation_capIsConcurrent(uint256 first, uint256 second) public {
        Reputation rep = new Reputation(passport, FEE_RECIPIENT, 0, 0, 0, 0, address(this));
        uint256 cap = rep.cap(SUB_H, address(token), false);
        first = bound(first, 1, cap);
        second = bound(second, 1, cap);
        rep.admit(holder, _dealTag(), address(token), first, address(0), "");
        if (first + second > cap) {
            vm.expectRevert(Reputation.CapExceeded.selector);
            rep.admit(holder, _dealTag(), address(token), second, address(0), "");
        } else {
            rep.admit(holder, _dealTag(), address(token), second, address(0), "");
            assertEq(rep.inFlight(SUB_H, address(token)), first + second);
            rep.notifyTerminal(SUB_H, _cpTag(), address(token), second, IReputation.Close.Silent);
        }
        rep.notifyTerminal(SUB_H, _cpTag(), address(token), first, IReputation.Close.Silent);
        assertEq(rep.score(SUB_H, address(token)), 0, "silent close changed the score");
        assertEq(rep.inFlight(SUB_H, address(token)), 0);
    }

    // --- BondVault -----------------------------------------------------------------------------------------

    /// lock = ceil(principal/10); reserve fails iff it exceeds available; withdraw is bounded by available.
    function testFuzz_bondVault_lockTenPercentOfAvailable(uint256 deposit, uint256 principal, uint256 withdrawAmt)
        public
    {
        deposit = bound(deposit, 1, type(uint128).max);
        principal = bound(principal, 1, type(uint128).max);
        BondVault vault = new BondVault(address(this), SINK, passport);
        token.mint(holder, deposit);
        vm.startPrank(holder);
        token.approve(address(vault), deposit);
        vault.deposit(SUB_H, address(token), deposit);
        vm.stopPrank();

        uint256 lock = (principal + 9) / 10;
        assertGe(lock * 10, principal, "lock under 10%");
        if (lock > deposit) {
            vm.expectRevert(BondVault.InsufficientAvailable.selector);
            vault.reserve(SUB_H, address(token), bytes32("deal"), principal, "");
            return;
        }
        vault.reserve(SUB_H, address(token), bytes32("deal"), principal, "");
        assertEq(vault.lockOf(SUB_H, bytes32("deal")), lock);
        assertEq(vault.available(SUB_H, address(token)), deposit - lock);

        withdrawAmt = bound(withdrawAmt, 0, deposit);
        vm.prank(holder);
        if (withdrawAmt > deposit - lock) {
            vm.expectRevert(BondVault.InsufficientAvailable.selector);
            vault.withdraw(SUB_H, address(token), withdrawAmt);
        } else {
            vault.withdraw(SUB_H, address(token), withdrawAmt);
            assertEq(token.balanceOf(holder), withdrawAmt);
        }
        vault.unlock(SUB_H, address(token), bytes32("deal"));
        assertEq(vault.locked(SUB_H, address(token)), 0);
        assertEq(vault.lockOf(SUB_H, bytes32("deal")), 0);
    }

    /// Slash moves exactly the loser's lock to the winner's signing address and releases the winner's own lock.
    function testFuzz_bondVault_slashPaysWinnerExactly(uint256 principal, address winner) public {
        principal = bound(principal, 1, type(uint128).max);
        vm.assume(winner != address(0) && winner != SINK && winner != holder && winner != provider);
        vm.assume(winner.code.length == 0);
        BondVault vault = new BondVault(address(this), SINK, passport);
        uint256 lock = (principal + 9) / 10;
        _fundBond(vault, holder, SUB_H, lock);
        _fundBond(vault, provider, SUB_P, lock);
        vault.reserve(SUB_H, address(token), bytes32("d"), principal, "");
        vault.reserve(SUB_P, address(token), bytes32("d"), principal, "");

        vault.slash(SUB_P, SUB_H, address(token), bytes32("d"), winner, address(0), 0);

        assertEq(token.balanceOf(winner), lock, "winner != loser lock");
        assertEq(token.balanceOf(SINK), 0, "slash burned");
        assertEq(vault.deposited(SUB_P, address(token)), 0, "loser keeps slashed deposit");
        assertEq(vault.deposited(SUB_H, address(token)), lock, "winner deposit touched");
        assertEq(vault.available(SUB_H, address(token)), lock, "winner lock not released");
        assertEq(vault.locked(SUB_H, address(token)) + vault.locked(SUB_P, address(token)), 0);
    }

    function testFuzz_bondVault_burnSendsBothLocksToSink(uint256 principal, uint256 extra) public {
        principal = bound(principal, 1, type(uint128).max);
        extra = bound(extra, 0, type(uint128).max);
        BondVault vault = new BondVault(address(this), SINK, passport);
        uint256 lock = (principal + 9) / 10;
        _fundBond(vault, holder, SUB_H, lock + extra);
        _fundBond(vault, provider, SUB_P, lock);
        vault.reserve(SUB_H, address(token), bytes32("d"), principal, "");
        vault.reserve(SUB_P, address(token), bytes32("d"), principal, "");
        vault.burn(SUB_H, SUB_P, address(token), bytes32("d"));
        assertEq(token.balanceOf(SINK), 2 * lock, "burn != both locks");
        assertEq(vault.available(SUB_H, address(token)), extra, "unlocked skin burned");
        assertEq(token.balanceOf(address(vault)), extra);
    }

    /// Only the operator (escrow) drives reserve / unlock / slash / burn.
    function testFuzz_bondVault_onlyOperator(address caller) public {
        vm.assume(caller != address(this));
        assumeNotForgeAddress(caller);
        BondVault vault = new BondVault(address(this), SINK, passport);
        vm.startPrank(caller);
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.reserve(SUB_H, address(token), bytes32("d"), 10, "");
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.unlock(SUB_H, address(token), bytes32("d"));
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.slash(SUB_H, SUB_P, address(token), bytes32("d"), holder, address(0), 0);
        vm.expectRevert(BondVault.Unauthorized.selector);
        vault.burn(SUB_H, SUB_P, address(token), bytes32("d"));
        vm.stopPrank();
    }

    // --- PackageId: policy is content-addressed --------------------------------------------------------------

    function testFuzz_packageId_bindsModuleAndPolicy(
        address m1,
        address m2,
        address r1,
        address r2,
        uint256 a1,
        uint256 a2,
        uint256 c1,
        uint256 c2,
        uint256 t1,
        uint256 t2,
        uint256 f1,
        uint256 f2
    ) public pure {
        vm.assume(m1 != m2 || r1 != r2 || a1 != a2 || c1 != c2 || t1 != t2 || f1 != f2);
        assertNotEq(PackageId.reputation(m1, r1, a1, c1, t1, f1), PackageId.reputation(m2, r2, a2, c2, t2, f2));
    }

    function testFuzz_packageId_kindsNeverCollide(address a, address b, uint256 k) public pure {
        bytes32[5] memory ids = [
            PackageId.passport(a),
            PackageId.bonds(a, b),
            PackageId.reputation(a, b, k, k, 0, 0),
            PackageId.arbitration(a, b, k, 0, address(0), 0, 0),
            PackageId.zk(a, b, b, k)
        ];
        for (uint256 i; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                assertNotEq(ids[i], ids[j], "two kinds hash to the same id");
            }
        }
    }

    /// A relayer cannot swap in a module whose live policy hashes to a different id than the one signed.
    function testFuzz_activate_rejectsUnsignedModule(uint256 signedFee, uint256 liveFee) public {
        signedFee = bound(signedFee, 0, 10_000);
        liveFee = bound(liveFee, 0, 10_000);
        vm.assume(signedFee != liveFee);
        Reputation signed = new Reputation(passport, FEE_RECIPIENT, 0, signedFee, 0, 0, address(escrow));
        Reputation live = new Reputation(passport, FEE_RECIPIENT, 0, liveFee, 0, 0, address(escrow));
        DealTerms memory t = _terms(1e6);
        t.packageIds = _sorted2(passport.packageId(), signed.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(live);
        token.mint(holder, 1e6);
        HolderAuthorization memory ha = HolderAuthorization({terms: t, nonce: 1, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa = ProviderAgreement({terms: t, nonce: 1, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;
        bytes memory hs = _sign(HOLDER_PK, Consent.hashHolderAuthorization(ha));
        bytes memory ps = _sign(PROVIDER_PK, Consent.hashProviderAgreement(pa));
        vm.expectRevert(Packages.UnknownPackage.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
    }

    // --- helpers -------------------------------------------------------------------------------------------

    function _terms(uint256 principal) internal view returns (DealTerms memory t) {
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = address(token);
        t.principal = principal;
        t.fiatDuration = 3600;
        t.releaseDuration = 1800;
        t.disputeDuration = 7200;
        t.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        t.arbitrationDuration = 7200;
    }

    function _activateWithRep(IReputation rep, uint256 principal) internal returns (bytes32) {
        DealTerms memory t = _terms(principal);
        t.packageIds = _sorted2(passport.packageId(), rep.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(rep);
        token.mint(holder, principal + rep.activationBps());
        return _activate(t, mods);
    }

    function _activate(DealTerms memory t, PackageMods memory mods) internal returns (bytes32) {
        HolderAuthorization memory ha = HolderAuthorization({terms: t, nonce: 1, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa = ProviderAgreement({terms: t, nonce: 1, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;
        return escrow.activate(
            ha,
            _sign(HOLDER_PK, Consent.hashHolderAuthorization(ha)),
            pa,
            _sign(PROVIDER_PK, Consent.hashProviderAgreement(pa)),
            ca,
            "",
            mods
        );
    }

    function _coSignedRelease(bytes32 id) internal {
        uint256 deadline = block.timestamp + 1 days;
        CoSignedRelease memory p = CoSignedRelease({dealId: id, nonce: 2, deadline: deadline});
        CoSignedRelease memory c = CoSignedRelease({dealId: id, nonce: 2, deadline: deadline});
        escrow.coSignedRelease(
            p, _sign(PROVIDER_PK, Consent.hashCoSignedRelease(p)), c, _sign(HOLDER_PK, Consent.hashCoSignedRelease(c))
        );
    }

    function _mutualSplit(bytes32 id, uint16 bps) internal {
        uint256 deadline = block.timestamp + 1 days;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: bps, nonce: 2, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: bps, nonce: 2, deadline: deadline});
        escrow.mutualSplit(
            p, _sign(PROVIDER_PK, Consent.hashMutualSplit(p)), c, _sign(HOLDER_PK, Consent.hashMutualSplit(c))
        );
    }

    function _fundBond(BondVault vault, address wallet, bytes32 subject, uint256 amount) internal {
        token.mint(wallet, amount);
        vm.startPrank(wallet);
        token.approve(address(vault), amount);
        vault.deposit(subject, address(token), amount);
        vm.stopPrank();
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash));
        return abi.encodePacked(r, s, v);
    }

    function _tier(uint256 score) internal pure returns (uint256 base, uint256 bonded) {
        if (score >= 100) return (type(uint256).max, type(uint256).max);
        if (score >= 50) return (2000e6, 5000e6);
        if (score >= 25) return (1000e6, 1500e6);
        if (score >= 10) return (500e6, 700e6);
        return (250e6, 400e6);
    }

    function _sorted2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        (ids[0], ids[1]) = a < b ? (a, b) : (b, a);
    }

    function _sorted3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory ids) {
        bytes32[3] memory xs = [a, b, c];
        for (uint256 i; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (xs[j] < xs[i]) (xs[i], xs[j]) = (xs[j], xs[i]);
            }
        }
        ids = new bytes32[](3);
        (ids[0], ids[1], ids[2]) = (xs[0], xs[1], xs[2]);
    }
}
