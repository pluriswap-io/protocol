// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployPrivate} from "../script/DeployPrivate.s.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {BundleVerifier} from "../src/packages/adapters/BundleVerifier.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DeployPrivate wiring tests
/// @notice The private layer of §E.3.15 was closed in tests and had never been deployed, so the only
///         wiring that had ever been exercised was each test file's own. This puts the DEPLOY
///         SCRIPT's wiring under real proofs, so the two cannot drift apart.
/// @dev What is actually at risk here is the circle: the accounts tree is owned by the reputation,
///      the reputation's bound vault is the vault, the vault gates on the reputation. The script
///      breaks it by CREATE prediction off the deployer's nonce, and an off-by-one there is a stack
///      that deploys cleanly and is wired to the wrong addresses forever.
contract DeployPrivateTest is Test {
    using stdJson for string;

    DeployPrivate internal script;
    address internal constant ESCROW = address(0xE5C0);
    address internal constant TOKEN = address(0x70CE);
    address internal constant POOL_FACTORY = address(0xFAC7);

    function setUp() public {
        PoseidonSingletons.install();
        script = new DeployPrivate();
        // The panel prices its dispute fee in whole deal tokens, so the deal token has to say its decimals.
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
    }

    function _deploy() internal returns (DeployPrivate.Stack memory s) {
        bytes32 registryId = bytes32(vm.readFile("test/fixtures/vectors.json").readUint(".registry.registry_id"));
        address decoder = address(new PassportDecoderMock(200_000, 1 days));
        // The script predicts off the CALLER's nonce, and here the caller is the script contract.
        (s,) = script.deployStack(address(script), ESCROW, registryId, decoder, TOKEN, POOL_FACTORY);
    }

    function test_deployStack_closesTheWiringCircle() public {
        DeployPrivate.Stack memory s = _deploy();
        assertEq(s.accountTree.owner(), address(s.reputation), "tree owner");
        assertEq(s.reputation.bondsVault(), address(s.vault), "rep -> vault");
        assertEq(address(s.vault.reputation()), address(s.reputation), "vault -> rep");
        assertEq(address(s.passport.accountTree()), address(s.accountTree), "passport -> tree");
        assertEq(address(s.reputation.accountTree()), address(s.accountTree), "rep -> tree");
        assertEq(address(s.vault.passport()), address(s.passport), "vault -> passport");
    }

    /// The kernel only ever reaches these through `Packages.resolve`, which re-derives each id from
    /// the live module and its policy. A deployment whose ids do not match is a deployment no signed
    /// deal can name.
    function test_deployStack_packageIdsResolveAsTheKernelWouldDeriveThem() public {
        DeployPrivate.Stack memory s = _deploy();
        assertEq(s.passport.packageId(), PackageId.passport(address(s.passport)), "passport id");
        assertEq(
            s.reputation.packageId(),
            PackageId.reputation(
                address(s.reputation),
                s.reputation.feeRecipient(),
                s.reputation.activationBps(),
                s.reputation.completionBps(),
                s.reputation.contestBps(),
                s.reputation.contestFloor()
            ),
            "reputation id"
        );
        assertEq(s.vault.packageId(), PackageId.bonds(address(s.vault), s.vault.sink()), "bonds id");
        // `Packages.resolve` also demands both peers name the same passport.
        assertEq(address(s.reputation.passport()), address(s.passport), "rep peer");
        assertEq(address(s.vault.passport()), address(s.passport), "vault peer");
    }

    /// Anexo R, 2026-09-29: an official pool trades on the official private stack, identified by the factory.
    function test_deployStack_identifiesTheOfficialPools() public {
        assertEq(_deploy().passport.poolFactory(), POOL_FACTORY);
    }

    /// Anexo R, 2026-09-29: across from a pool a human vouches for the Provider. The shared verifier carries the
    /// `vouch` circuit, and the panel takes a vouch for exactly the pools the passport identifies.
    function test_deployStack_wiresTheVouchAcrossFromAPool() public {
        DeployPrivate.Stack memory s = _deploy();
        BundleVerifier bundle = BundleVerifier(address(s.passport.bundleVerifier()));
        assertTrue(bundle.vouchHonkVerifier() != address(0), "the vouch verifier deployed");
        assertEq(s.panel.poolFactory(), POOL_FACTORY, "the panel knows the pools the passport knows");
    }

    /// Anexo R, 2026-09-29 (D5): the official panel refuses an arbiter who is a party, at the human level —
    /// which only holds if it reads the SAME humanity domain and bundle verifier the sides prove under.
    function test_deployStack_shipsAPanelUnderTheHumanityRule() public {
        DeployPrivate.Stack memory s = _deploy();
        assertEq(address(s.panel.kernel()), ESCROW, "panel kernel");
        assertEq(address(s.panel.token()), TOKEN, "panel bonds in the deal token");
        assertEq(address(s.panel.humanityVerifier()), address(s.passport.humanityVerifier()), "same humanity");
        assertEq(address(s.panel.bundleVerifier()), address(s.passport.bundleVerifier()), "same bundle verifier");
        assertEq(
            s.panel.registryId(), bytes32(vm.readFile("test/fixtures/vectors.json").readUint(".registry.registry_id"))
        );
        assertEq(s.panel.availabilityBps(), 20, "0.2% per arbiter");
        assertEq(s.panel.activationBps(), 60, "three arbiters' availability");
        assertEq(s.panel.contestFee(), 0, "opening the court costs nothing (Anexo R, 2026-10-05)");
        assertEq(s.panel.bondShareBps(), 3_000, "30% of the loser's bond pays the panel");
        assertEq(s.panel.bondVault(), address(s.vault), "the panel pins the stack's vault");
        assertEq(s.panel.commitWindow() + s.panel.revealWindow(), 4 days, "four days to answer");
        assertEq(s.panel.governor(), address(0xDA0), "the DAO moves the panel's terms (Anexo R, 2026-10-06)");
        assertEq(s.reputation.governor(), address(0xDA0), "the DAO moves the reputation's fees (Anexo R, 2026-10-06)");
        assertTrue(s.reputation.governor() != s.reputation.feeRecipient(), "the governance is not the treasury");
        assertEq(s.panel.exitDelay(), 14 days, "a 14-day exit");
    }

    function test_deployStack_operatorIsTheEscrowEverywhere() public {
        DeployPrivate.Stack memory s = _deploy();
        assertEq(s.reputation.operator(), ESCROW);
        assertEq(s.vault.operator(), ESCROW);
    }

    /// The real proof leg: a committed `register_humanity` + `register_account` bundle must verify
    /// against a stack this script built, not one a test file hand-wired. That exercises the
    /// registry domain, both Honk adapters and the account tree in one shot.
    function test_deployStack_takesTheCommittedRegisterProofs() public {
        vm.warp(1_700_000_000);
        string memory vectors = vm.readFile("test/fixtures/vectors.json");
        DeployPrivate.Stack memory s = _deploy();

        address anchor = makeAddr("anchor");
        PassportDecoderMock(s.decoder).setScore(anchor, 200_000, uint64(block.timestamp + 30 days));
        // Resolve the commitment BEFORE the prank: an intervening call would eat it.
        bytes32 commitment = s.registry.identityCommitmentOf(bytes32(vectors.readUint(".registry.hsk")));
        vm.prank(anchor);
        s.registry.enroll(commitment);

        bytes32 hn = bytes32(vectors.readUint(".registry.sample_hn"));
        bytes32 leaf0 = bytes32(vectors.readUint(".registry.sample_leaf0"));
        s.passport
            .register(
                vm.readFile("test/fixtures/proofs/register_humanity.json").readBytes(".proof_with_public_inputs"), hn
            );
        s.reputation
            .register(
                vm.readFile("test/fixtures/proofs/register_account.json").readBytes(".proof_with_public_inputs"),
                hn,
                leaf0
            );

        assertTrue(s.passport.humanitySpent(hn), "humanity not burned");
        assertTrue(s.reputation.registeredHn(hn), "account not registered");
        assertEq(s.accountTree.nextIndex(), 1, "leaf0 not inserted");
        assertTrue(s.accountTree.isKnownRoot(s.accountTree.root()), "root not in the window");
    }
}
