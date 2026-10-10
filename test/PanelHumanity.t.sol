// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods,
    PackageData
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {ArbiterRegistry} from "../src/packages/ArbiterRegistry.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {VouchData} from "../src/packages/libraries/VouchData.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {BundleVerifierMock} from "../mocks/BundleVerifierMock.sol";
import {BaseTest} from "./Base.t.sol";
import {PanelBonds} from "./PanelBonds.sol";

/// @title The arbiter is not a party — as a human, not only as a wallet
/// @notice PROTOCOLO.md Anexo R, 2026-09-29. Arbiters register their humanity nullifier with the same proof an
///         account registers with; each private side of the deal proves, in its `prepare_side`, that its own
///         nullifier under this registry is none of the panel's. The court checks at `bind` that both sides did,
///         for exactly this panel and this registry — a party who is also an arbiter has no such proof.
contract PanelHumanityTest is BaseTest, PanelBonds {
    bytes32 internal constant REGISTRY_ID = keccak256("pluri:humanity-registry:v1");
    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    ArbiterRegistry internal registry;
    BundleVerifierMock internal bundle;
    uint256[3] internal pks = [uint256(0xA1), uint256(0xA2), uint256(0xA3)];
    address[3] internal arbs;
    bytes32[3] internal hns = [keccak256("hn-1"), keccak256("hn-2"), keccak256("hn-3")];

    function setUp() public override {
        super.setUp();
        bundle = new BundleVerifierMock();
        _deployBonds(address(escrow));
        _bondSide(token, holder, PRINCIPAL);
        _bondSide(token, provider, PRINCIPAL);
        registry = new ArbiterRegistry(
            address(escrow),
            address(token),
            ArbiterRegistry.Policy(1 days, 1 days, 7 days, 1_000, 5_000, 20, 3_000),
            address(0),
            address(bondVault),
            address(new HumanityVerifierMock()),
            address(bundle),
            REGISTRY_ID,
            address(0)
        );
        for (uint256 i; i < 3; i++) {
            arbs[i] = vm.addr(pks[i]);
            token.mint(arbs[i], PRINCIPAL);
            vm.startPrank(arbs[i]);
            token.approve(address(registry), type(uint256).max);
            registry.deposit(PRINCIPAL);
            registry.registerHumanity(abi.encode(true), hns[i]);
            registry.setEncryptionKey(keccak256(abi.encode("x25519", i)));
            vm.stopPrank();
        }
        token.mint(holder, PRINCIPAL);
    }

    function test_bothSidesProvedTheyAreNotThePanel_binds() public {
        _activate(_side(REGISTRY_ID, hns), _side(REGISTRY_ID, hns));
    }

    function test_aSideForAnotherPanel_isRefused() public {
        bytes32[3] memory other = [hns[0], hns[1], keccak256("somebody else")];
        _expectRevert(_side(REGISTRY_ID, hns), _side(REGISTRY_ID, other), ArbiterRegistry.PanelMismatch.selector);
    }

    function test_aSideUnderAnotherRegistry_isRefused() public {
        _expectRevert(
            _side(REGISTRY_ID, hns),
            _side(keccak256("a registry of my own"), hns),
            ArbiterRegistry.RegistryMismatch.selector
        );
    }

    function test_aSideNobodyProved_isRefused() public {
        bundle.setAnswer(false);
        _expectRevert(_side(REGISTRY_ID, hns), _side(REGISTRY_ID, hns), ArbiterRegistry.HumanityUnproven.selector);
    }

    function test_aDealWithoutPrivateSides_cannotUseAHumanPanel() public {
        _expectRevert("", "", ArbiterRegistry.HumanityUnproven.selector);
    }

    /// A vouch is a pool's side (Anexo R, 2026-09-29). A person who sits on the panel cannot present somebody
    /// else's vouch instead of their own proof: the court only takes a vouch for an official pool.
    function test_aPersonCannotHideBehindAVouch() public {
        IBundleVerifier.VouchInputs memory v;
        v.registryId = REGISTRY_ID;
        v.arbiters = hns;
        _expectRevert(
            VouchData.encode(v, abi.encode(true)), _side(REGISTRY_ID, hns), ArbiterRegistry.HumanityUnproven.selector
        );
    }

    function test_anArbiterWithoutHumanity_cannotSit() public {
        address stranger = vm.addr(0xA4);
        token.mint(stranger, PRINCIPAL);
        vm.startPrank(stranger);
        token.approve(address(registry), type(uint256).max);
        registry.deposit(PRINCIPAL);
        registry.setEncryptionKey(keccak256("x25519 stranger"));
        vm.stopPrank();
        arbs[2] = stranger;
        pks[2] = 0xA4;
        _expectRevert(_side(REGISTRY_ID, hns), _side(REGISTRY_ID, hns), ArbiterRegistry.ArbiterNotHuman.selector);
    }

    function test_oneHumanOneArbiterSeat() public {
        address second = address(0xB5);
        vm.prank(second);
        vm.expectRevert(ArbiterRegistry.HumanTaken.selector);
        registry.registerHumanity(abi.encode(true), hns[0]);
    }

    /// A panel of one (Anexo R, 2026-09-29): the side proves against the one arbiter and two empty seats — the
    /// zero hn, which no human's nullifier is.
    function test_aPanelOfOne_bindsWhenBothSidesProvedAgainstIt() public {
        arbs[1] = address(0);
        arbs[2] = address(0);
        bytes32[3] memory solo = [hns[0], bytes32(0), bytes32(0)];
        _activate(_side(REGISTRY_ID, solo), _side(REGISTRY_ID, solo));
    }

    function test_aPanelOfOne_refusesASideProvedAgainstThree() public {
        arbs[1] = address(0);
        arbs[2] = address(0);
        bytes32[3] memory solo = [hns[0], bytes32(0), bytes32(0)];
        _expectRevert(_side(REGISTRY_ID, solo), _side(REGISTRY_ID, hns), ArbiterRegistry.PanelMismatch.selector);
    }

    // --- helpers ----------------------------------------------------------------------------------------

    function _side(bytes32 registryId, bytes32[3] memory arbiters) internal pure returns (bytes memory) {
        IBundleVerifier.BundleInputs memory i;
        i.registryId = registryId;
        i.arbiters = arbiters;
        return abi.encode(i, bytes(""));
    }

    function _terms() internal view returns (DealTerms memory t) {
        t = _p2pTerms();
        t.arbitrationDuration = 3 days;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.packageId();
        t.packageIds = _withBondIds(ids);
    }

    function _data(bytes32 id, bytes memory h, bytes memory p) internal view returns (PackageData memory data) {
        bytes32 digest = registry.appointmentDigest(id, arbs);
        bytes[3] memory accepts;
        for (uint256 k; k < 3; k++) {
            accepts[k] = _sign(digest, pks[k]);
        }
        data.court = abi.encode(arbs, _sign(digest, holderPk), _sign(digest, providerPk), accepts);
        data.holder = _withDeal(h, id);
        data.provider = _withDeal(p, id);
    }

    /// @dev Sides are built before the deal id is known; stamp it in.
    function _withDeal(bytes memory side, bytes32 id) internal pure returns (bytes memory) {
        if (side.length == 0 || bytes32(side) == VouchData.TAG) return side;
        (IBundleVerifier.BundleInputs memory i, bytes memory proof) =
            abi.decode(side, (IBundleVerifier.BundleInputs, bytes));
        i.dealId = id;
        return abi.encode(i, proof);
    }

    function _activate(bytes memory h, bytes memory p) internal {
        DealTerms memory t = _terms();
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        PackageMods memory mods;
        mods.court = address(registry);
        mods = _withBondMods(mods);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca;
        escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods, _data(id, h, p));
    }

    function _expectRevert(bytes memory h, bytes memory p, bytes4 selector) internal {
        DealTerms memory t = _terms();
        bytes32 id = Consent.dealId(escrow.domainSeparator(), t, 1, 1, 0);
        PackageMods memory mods;
        mods.court = address(registry);
        mods = _withBondMods(mods);
        HolderAuthorization memory ha = _holderAuth(t, 1);
        ProviderAgreement memory pa = _providerAuth(t, 1);
        ControllerAcceptance memory ca;
        PackageData memory data = _data(id, h, p);
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        vm.expectRevert(selector);
        escrow.activate(ha, hs, pa, ps, ca, "", mods, data);
    }
}
