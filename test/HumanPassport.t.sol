// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {HumanPassport} from "../mocks/HumanPassport.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IGitcoinPassportDecoder} from "../src/packages/interfaces/IGitcoinPassportDecoder.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BondVault} from "../mocks/BondVault.sol";
import {BaseTest} from "./Base.t.sol";

/// @dev PASSPORT over Human Passport: wallet -> subject iff the decoder reports a live, passing score.
contract HumanPassportTest is BaseTest {
    uint256 internal constant THRESHOLD = 200_000; // 20.0000
    uint64 internal constant MAX_AGE = 90 days;
    uint256 internal constant ACT_BPS = 1_000;
    uint256 internal constant COMP_BPS = 500;
    uint256 internal constant ACT_FEE = PRINCIPAL * ACT_BPS / 10_000;
    uint256 internal constant COMP_FEE = PRINCIPAL * COMP_BPS / 10_000;
    uint256 internal constant BOND = PRINCIPAL / 10;

    PassportDecoderMock internal decoder;
    HumanPassport internal passport;
    Reputation internal reputation;
    BondVault internal vault;
    address internal feeRecipient = address(0xFEE);
    address internal sink = address(0xdeaD);

    function setUp() public override {
        super.setUp();
        decoder = new PassportDecoderMock(THRESHOLD, MAX_AGE);
        passport = new HumanPassport(decoder, 0);
        reputation = new Reputation(passport, feeRecipient, ACT_BPS, COMP_BPS, 0, 0, address(escrow));
        vault = new BondVault(address(escrow), sink, passport);

        decoder.setScore(holder, 250_000, 0);
        decoder.setScore(provider, THRESHOLD, 0);
        token.mint(holder, ACT_FEE + BOND);
        token.mint(provider, BOND);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(provider);
        token.approve(address(vault), type(uint256).max);
    }

    // --- identify ---------------------------------------------------------------------------------

    function test_identify_subjectIsWallet() public view {
        assertEq(passport.identify(holder, holder, bytes32(0), ""), bytes32(uint256(uint160(holder))));
        assertEq(passport.identify(holder, holder, bytes32(0), ""), passport.subjectOf(holder));
        assertTrue(passport.isHuman(holder));
    }

    function test_identify_atThresholdPasses() public view {
        assertEq(passport.identify(provider, provider, bytes32(0), ""), passport.subjectOf(provider));
    }

    function test_identify_belowThresholdReverts() public {
        decoder.setScore(provider, THRESHOLD - 1, 0);
        assertFalse(passport.isHuman(provider));
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(provider, provider, bytes32(0), "");
    }

    function test_identify_noAttestationReverts() public {
        address stranger = address(0x5717);
        assertFalse(passport.isHuman(stranger));
        (uint256 s, bool live) = passport.score(stranger);
        assertEq(s, 0);
        assertFalse(live);
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(stranger, stranger, bytes32(0), "");
    }

    function test_identify_expiredReverts() public {
        decoder.setScore(provider, 300_000, uint64(block.timestamp + 1 days));
        assertTrue(passport.isHuman(provider));
        vm.warp(block.timestamp + 1 days);
        assertFalse(passport.isHuman(provider));
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(provider, provider, bytes32(0), "");
    }

    function test_identify_maxScoreAgeApplies() public {
        vm.warp(block.timestamp + MAX_AGE);
        assertFalse(passport.isHuman(holder), "score older than maxScoreAge still human");
    }

    function test_identify_decoderPausedFailsClosed() public {
        decoder.setPaused(true);
        assertFalse(passport.isHuman(holder));
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(holder, holder, bytes32(0), "");
    }

    function test_minScore_overridesDecoderThreshold() public {
        HumanPassport strict = new HumanPassport(decoder, 300_000);
        assertTrue(passport.isHuman(holder), "decoder threshold passes 25.0");
        assertFalse(strict.isHuman(holder), "adapter minScore 30.0 rejects 25.0");
        decoder.setScore(holder, 300_000, 0);
        assertTrue(strict.isHuman(holder));
        // Decoder threshold is irrelevant once the adapter pins its own.
        decoder.setThreshold(1_000_000);
        assertTrue(strict.isHuman(holder));
        assertFalse(passport.isHuman(holder));
    }

    function test_packageId_bindsAdapterNotDecoder() public {
        HumanPassport twin = new HumanPassport(decoder, 0);
        assertNotEq(passport.packageId(), twin.packageId(), "same policy, different address, same id");
    }

    function test_constructor_rejectsZeroDecoder() public {
        vm.expectRevert(HumanPassport.ZeroDecoder.selector);
        new HumanPassport(IGitcoinPassportDecoder(address(0)), 0);
    }

    function testFuzz_isHuman_iffScoreAtLeastMinScore(uint256 score, uint256 minScore) public {
        minScore = bound(minScore, 1, type(uint128).max);
        HumanPassport p = new HumanPassport(decoder, minScore);
        decoder.setScore(holder, score, 0);
        assertEq(p.isHuman(holder), score >= minScore);
    }

    // --- kernel integration --------------------------------------------------------------------------

    function test_trio_activatesWithHumanPassport() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        (bytes32 h, bytes32 p) = escrow.subjects(id);
        assertEq(h, passport.subjectOf(holder));
        assertEq(p, passport.subjectOf(provider));
        assertEq(vault.lockOf(passport.subjectOf(holder), id), BOND);
        assertEq(reputation.inFlight(passport.subjectOf(provider), address(token)), PRINCIPAL);
    }

    function test_trio_providerWithoutPassport_failsClosed() public {
        _fundBonds();
        decoder.clear(provider);
        DealTerms memory terms = _trioTerms();
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        PackageMods memory mods = _trioMods();
        vm.expectRevert(IPassport.NoPassport.selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods);
        assertFalse(escrow.used(holder, 1), "nonce burned by a rejected activation");
        assertEq(token.balanceOf(feeRecipient), 0, "activation fee charged without a deal");
    }

    /// ADM-05: a Passport that lapses after activation changes nothing for the live deal or its terminal.
    function test_passportLapsesMidDeal_terminalStillCommitsAndCredits() public {
        _fundBonds();
        bytes32 id = _activateTrio(1, 1);
        bytes32 subP = passport.subjectOf(provider);
        uint256 scoreBefore = reputation.score(subP, address(token));

        decoder.clear(holder);
        decoder.clear(provider);
        assertFalse(passport.isHuman(provider));

        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);

        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(reputation.inFlight(subP, address(token)), 0, "inFlight orphaned after lapse");
        assertGt(reputation.score(subP, address(token)), scoreBefore, "peaceful close not credited to snapshot");
        assertEq(vault.lockOf(subP, id), 0, "bond not unlocked after lapse");
    }

    /// Bond withdrawal is gated by a *live* identify: a lapsed Passport parks the skin until re-verification.
    /// Documented liveness dependency (stamps expire); funds are not lost, the human re-verifies the same wallet.
    function test_bondWithdraw_requiresLivePassport() public {
        _fundBonds();
        bytes32 subP = passport.subjectOf(provider);
        decoder.clear(provider);
        vm.prank(provider);
        vm.expectRevert(IPassport.NoPassport.selector);
        vault.withdraw(subP, address(token), BOND);

        decoder.setScore(provider, THRESHOLD, 0);
        vm.prank(provider);
        vault.withdraw(subP, address(token), BOND);
        assertEq(token.balanceOf(provider), BOND);
    }

    /// Passport is per wallet: a second wallet of the same human is a new subject with no history.
    function test_secondWallet_isNewSubject() public {
        address second = address(0x5EC);
        decoder.setScore(second, THRESHOLD, 0);
        assertNotEq(
            passport.identify(second, second, bytes32(0), ""), passport.identify(holder, holder, bytes32(0), "")
        );
        assertEq(reputation.score(passport.subjectOf(second), address(token)), 0);
    }

    // --- helpers ----------------------------------------------------------------------------------------

    function _fundBonds() internal {
        bytes32 subH = passport.subjectOf(holder);
        bytes32 subP = passport.subjectOf(provider);
        vm.prank(holder);
        vault.deposit(subH, address(token), BOND);
        vm.prank(provider);
        vault.deposit(subP, address(token), BOND);
    }

    function _trioTerms() internal view returns (DealTerms memory terms) {
        terms = _p2pTerms();
        bytes32[3] memory xs = [passport.packageId(), reputation.packageId(), vault.packageId()];
        for (uint256 i; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (xs[j] < xs[i]) (xs[i], xs[j]) = (xs[j], xs[i]);
            }
        }
        terms.packageIds = new bytes32[](3);
        (terms.packageIds[0], terms.packageIds[1], terms.packageIds[2]) = (xs[0], xs[1], xs[2]);
    }

    function _trioMods() internal view returns (PackageMods memory m) {
        m.passport = address(passport);
        m.reputation = address(reputation);
        m.bonds = address(vault);
    }

    function _activateTrio(uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
        DealTerms memory terms = _trioTerms();
        HolderAuthorization memory ha = _holderAuth(terms, hNonce);
        ProviderAgreement memory pa = _providerAuth(terms, pNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", _trioMods());
    }
}
