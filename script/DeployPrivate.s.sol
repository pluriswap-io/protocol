// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ChainIds} from "./ChainIds.s.sol";
import {PoseidonEnsurer} from "./Poseidon.s.sol";
import {PoseidonTree, DEFAULT_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {HumanityRegistry} from "../src/packages/HumanityRegistry.sol";
import {ArbiterRegistry} from "../src/packages/ArbiterRegistry.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";
import {IGitcoinPassportDecoder} from "../src/packages/interfaces/IGitcoinPassportDecoder.sol";
import {RegistryHumanityVerifier} from "../src/packages/adapters/RegistryHumanityVerifier.sol";
import {RegistryAccountVerifier} from "../src/packages/adapters/RegistryAccountVerifier.sol";
import {BundleVerifier} from "../src/packages/adapters/BundleVerifier.sol";
import {ClaimVerifier} from "../src/packages/adapters/ClaimVerifier.sol";
import {DepositVerifier} from "../src/packages/adapters/DepositVerifier.sol";
import {ReabsorbVerifier} from "../src/packages/adapters/ReabsorbVerifier.sol";
import {WithdrawVerifier} from "../src/packages/adapters/WithdrawVerifier.sol";
import {PassportDecoderMock} from "../mocks/PassportDecoderMock.sol";

/// @title DeployPrivate
/// @notice The private layer of PROTOCOLO.md §E.3.15, as one deployment: Poseidon singletons, the
///         humanity registry, the nine real Honk verifier adapters, and the passport / reputation /
///         bond-vault triangle behind the kernel's `IPassport`, `IReputation` and `IBondVault`.
/// @dev F1–F4 closed in tests and had never been deployed. This is that gap.
///
///      Two things make the order non-obvious and both are load-bearing:
///
///      * **The wiring circle.** The accounts tree's owner is the reputation, the reputation's bound
///        vault is the vault, and the vault's gating reputation is the reputation. Broken exactly as
///        the tests break it — by CREATE prediction off the deployer's nonce, with every constructor
///        argument already deployed before the prediction is taken, so the count cannot drift. The
///        script asserts both predictions landed rather than trusting the arithmetic.
///      * **Nothing here is linked.** The Honk verifiers are deployed by their adapters from
///        committed initcode (`test/fixtures/verifiers/`), and Poseidon is the pinned upstream
///        deployment (§E.5.1) — `ensurePoseidon` puts it there on a chain that lacks it, which on
///        Arbitrum today means `PoseidonT2`.
///
///      Test chains only. The humanity gate needs a Passport decoder, and off Arbitrum One that is
///      `PassportDecoderMock`, whose `setScore` is unauthenticated — enrolment would be a free pass.
///      Arbitrum One is refused for a second reason that outlives the mock: the circuits are
///      unaudited and they touch money (§E.3.15.11).
///
///      `REGISTRY_ID` defaults to the canonical domain pinned in `test/fixtures/vectors.json`, so the
///      committed fixture proofs verify against this deployment and the whole stack can be smoke
///      tested on a testnet without a prover.
contract DeployPrivate is PoseidonEnsurer, ChainIds {
    using stdJson for string;

    /// @dev Mirrors `DeployPackages`: same fee policy, so the private and public reputation packages
    ///      are comparable. Placeholders, never a production identity (PROTOCOLO.md §E.5.7).
    ///      The 0.3% + 0.3% official shares are the kernel's since 2026-10-02, so this package charges neither.
    uint256 internal constant ACT_BPS = 0;
    uint256 internal constant COMP_BPS = 0;
    /// @dev An official deal moves at least one lot of 250 whole tokens (Anexo R, 2026-09-28).
    uint256 internal constant MIN_PRINCIPAL_LOTS = 1;
    uint256 internal constant CONTEST_BPS = 100;
    uint256 internal constant CONTEST_FLOOR = 2_000_000;
    /// @dev The treasury (PROTOCOLO.md §3.2): the DAO's receiving contract, where every official fee lands. It has no
    ///      power over any contract. Same placeholder as the kernel's `feeRecipient`.
    address internal constant TREASURY = address(0xFEE);
    address internal constant SINK = address(0xdeaD);
    /// @dev The official panel's policy, the same as `DeployPackages`' (Anexo R, 2026-09-28): 0.2% availability
    ///      per arbiter, 10% of the principal locked per arbiter, half of it lost by a lone abstainer; no dispute
    ///      fee but 30% of the loser's bond (2026-10-05); four days to answer, three to commit and one to reveal;
    ///      and a 14-day exit for the bond (2026-09-29).
    uint256 internal constant PANEL_AVAILABILITY_BPS = 20;
    uint256 internal constant PANEL_LOCK_BPS = 1_000;
    uint256 internal constant PANEL_ABSTAIN_SLASH_BPS = 5_000;
    uint256 internal constant PANEL_BOND_SHARE_BPS = 3_000;
    /// @dev Who may move the panel's terms and prices and the reputation's fees for the deals to come, inside each
    ///      package's bounds and after its delay (Anexo R, 2026-10-06): the DAO's governance (its timelock), never the
    ///      treasury. Two contracts, one sovereign: the one that receives has no verbs, and the one with verbs
    ///      receives nothing. A placeholder until the DAO exists, distinct from `TREASURY` so a mix-up shows.
    address internal constant DAO_GOVERNOR = address(0xDA0);

    struct Verifiers {
        RegistryHumanityVerifier humanity;
        RegistryAccountVerifier account;
        /// @dev One verifier for the whole side since 2026-09-23 (§E.3.15.4): the passport, admission
        ///      and split of one side are one proof, checked once and read by the three modules.
        BundleVerifier bundle;
        ClaimVerifier claim;
        DepositVerifier deposit;
        ReabsorbVerifier reabsorb;
        WithdrawVerifier withdraw;
    }

    struct Stack {
        address decoder;
        HumanityRegistry registry;
        PoseidonTree accountTree;
        PrivatePassport passport;
        PrivateReputation reputation;
        PrivateBondVault vault;
        /// @dev The tribunal of the official private stack: arbiters registered under the same humanity domain
        ///      the sides prove under, so a side's proof can show its human is not on the panel (D5).
        ArbiterRegistry panel;
    }

    function run() external {
        _requireMockChain("DeployPrivate");
        address escrow = _escrow();
        bytes32 registryId = _registryId();
        uint256 pk = _key();
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        ensurePoseidon();
        (Stack memory s, Verifiers memory v) =
            deployStack(deployer, escrow, registryId, _decoder(), _dealToken(), _poolFactory());
        vm.stopBroadcast();

        _report(s, v, escrow, registryId);
    }

    /// @notice The wiring itself, with nothing around it: no env, no broadcast, no JSON. `run` calls
    ///         it between `startBroadcast` and `stopBroadcast`; `test/DeployPrivate.t.sol` calls it
    ///         directly and then puts real proofs through what it built, so the deployed wiring and
    ///         the tested wiring cannot drift apart.
    /// @param deployer The address whose nonce the CREATE predictions are taken from — the caller.
    /// @param token The deal token the panel's arbiters bond in.
    /// @param poolFactory The factory whose pools the passport identifies without a proof; zero for none.
    function deployStack(
        address deployer,
        address escrow,
        bytes32 registryId,
        address decoder,
        address token,
        address poolFactory
    ) public returns (Stack memory s, Verifiers memory v) {
        s.decoder = decoder;
        s.registry = new HumanityRegistry(IGitcoinPassportDecoder(decoder), 0, registryId);
        v = _deployVerifiers(s.registry);

        // Before the prediction below, which reads the nonce after it: the court moves no prediction, and the deal
        // token dies here instead of staying live across the circle (the stack of this function is at its edge).
        // The panel pins the vault whose bonds every deal of it carries (Anexo R, 2026-10-05): the vault is the
        // fifth CREATE from here — panel, tree, passport, reputation, vault.
        s.panel = _deployPanel(
            PanelArgs({
                escrow: escrow,
                token: token,
                bondVault: vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 4),
                humanity: address(v.humanity),
                bundle: address(v.bundle),
                registryId: registryId,
                poolFactory: poolFactory
            })
        );

        // Prediction taken here, after every constructor argument exists: +2 is the reputation, +3
        // the vault. The vault's own notes tree is a CREATE by the vault, not by the deployer, so it
        // does not move this sequence.
        uint256 n = vm.getNonce(deployer);
        address predictedRep = vm.computeCreateAddress(deployer, n + 2);
        address predictedVault = vm.computeCreateAddress(deployer, n + 3);

        s.accountTree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predictedRep);
        s.passport = new PrivatePassport(s.accountTree, v.humanity, v.bundle, poolFactory);
        s.reputation = new PrivateReputation(
            s.passport,
            s.accountTree,
            v.account,
            v.bundle,
            v.claim,
            TREASURY,
            ACT_BPS,
            COMP_BPS,
            CONTEST_BPS,
            CONTEST_FLOOR,
            escrow,
            predictedVault,
            MIN_PRINCIPAL_LOTS,
            DAO_GOVERNOR
        );
        s.vault =
            new PrivateBondVault(s.passport, s.reputation, SINK, escrow, v.deposit, v.bundle, v.reabsorb, v.withdraw);

        require(address(s.reputation) == predictedRep, "reputation prediction drifted");
        require(address(s.vault) == predictedVault, "vault prediction drifted");
        require(s.accountTree.owner() == address(s.reputation), "account tree owner");
        require(s.reputation.operator() == escrow, "reputation operator");
        require(s.reputation.bondsVault() == address(s.vault), "reciprocal rep/vault binding");
        require(s.vault.operator() == escrow, "vault operator");
        require(address(s.vault.passport()) == address(s.passport), "vault peer passport");
        require(s.panel.bondVault() == address(s.vault), "panel pins the vault");
    }

    /// @dev What the panel is deployed with beyond the constants: in memory, because `deployStack` is at the edge of
    ///      the stack and the court's constructor is long.
    struct PanelArgs {
        address escrow;
        address token;
        address bondVault;
        address humanity;
        address bundle;
        bytes32 registryId;
        address poolFactory;
    }

    /// @dev The panel with the humanity rule, and the factory whose pools a human may vouch for across from it.
    function _deployPanel(PanelArgs memory a) internal returns (ArbiterRegistry) {
        return new ArbiterRegistry(
            a.escrow,
            a.token,
            ArbiterRegistry.Policy(
                3 days,
                1 days,
                14 days,
                uint16(PANEL_LOCK_BPS),
                uint16(PANEL_ABSTAIN_SLASH_BPS),
                uint16(PANEL_AVAILABILITY_BPS),
                uint16(PANEL_BOND_SHARE_BPS)
            ),
            DAO_GOVERNOR,
            a.bondVault,
            a.humanity,
            a.bundle,
            a.registryId,
            a.poolFactory
        );
    }

    function _deployVerifiers(HumanityRegistry registry) internal returns (Verifiers memory v) {
        v.humanity = new RegistryHumanityVerifier(registry, _initcode("register_humanity"));
        v.account = new RegistryAccountVerifier(registry, _initcode("register_account"), _initcode("upgrade_account"));
        v.bundle = _deployBundle();
        v.claim = new ClaimVerifier(_initcode("claim"));
        v.deposit = new DepositVerifier(_initcode("deposit"));
        v.reabsorb = new ReabsorbVerifier(_initcode("reabsorb"));
        v.withdraw = new WithdrawVerifier(_initcode("withdraw"));
    }

    /// @dev The shared verifier of both statements a side can make: a person's `prepare_side`, and a human's vouch
    ///      across from a pool (Anexo R, 2026-09-29).
    function _deployBundle() internal returns (BundleVerifier) {
        bytes memory side = _initcode("prepare_side");
        bytes memory vouch = _initcode("vouch");
        return new BundleVerifier(side, vouch);
    }

    /// @dev The generated Honk verifier of one circuit, as committed by `bun circuits:prove`. The
    ///      main tree cannot compile these (via_ir vs the generated dispatchers), which is why they
    ///      travel as initcode and each adapter CREATEs its own.
    function _initcode(string memory circuit) internal view returns (bytes memory) {
        return vm.readFile(string.concat("test/fixtures/verifiers/", circuit, ".json")).readBytes(".initcode");
    }

    function _decoder() internal returns (address decoder) {
        decoder = vm.envOr("PASSPORT_DECODER", address(0));
        if (decoder != address(0)) {
            require(decoder.code.length > 0, "passport decoder has no code on this chain");
            return decoder;
        }
        // `setScore` takes no authorisation: anyone can hand themselves a passing score and enrol.
        _requireMockChain("PassportDecoderMock");
        return address(new PassportDecoderMock(200_000, 1 days));
    }

    /// @dev The enrolment domain `hn` is nullified under. Defaults to the canonical one the circuit
    ///      vectors pin, so the committed fixture proofs verify against this deployment.
    function _registryId() internal view returns (bytes32) {
        bytes32 override_ = vm.envOr("REGISTRY_ID", bytes32(0));
        if (override_ != bytes32(0)) return override_;
        return bytes32(vm.readFile("test/fixtures/vectors.json").readUint(".registry.registry_id"));
    }

    /// @dev The deal token `DeployPackages` recorded, unless `TOKEN` names another.
    function _dealToken() internal view returns (address token) {
        token = vm.envOr("TOKEN", address(0));
        if (token == address(0)) token = vm.readFile(_packagesFile()).readAddress(".testToken");
        require(token.code.length > 0, "deal token has no code on this chain");
    }

    /// @dev The factory `DeployPoolFactory` recorded, unless `POOL_FACTORY` names one. Without either the
    ///      passport identifies no pools — a stack without pools is still a stack.
    function _poolFactory() internal view returns (address factory) {
        factory = vm.envOr("POOL_FACTORY", address(0));
        if (factory != address(0)) return factory;
        string memory f = block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia-pool-factory.json"
            : string.concat("deployments/", vm.toString(block.chainid), "-pool-factory.json");
        if (!vm.exists(f)) return address(0);
        factory = vm.readFile(f).readAddress(".factory");
        require(_addressOf(factory, "escrow()") == _escrow(), "the recorded pool factory pins another escrow");
    }

    function _addressOf(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    function _packagesFile() internal view returns (string memory) {
        return block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia-packages.json"
            : string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
    }

    function _escrow() internal view returns (address escrow) {
        escrow = vm.envOr("ESCROW", address(0));
        if (escrow != address(0)) return escrow;
        string memory packages = _packagesFile();
        require(vm.exists(packages), string.concat("no ESCROW and no ", packages));
        escrow = vm.readFile(packages).readAddress(".escrow");
        require(escrow.code.length > 0, "escrow has no code on this chain");
    }

    function _out() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-private.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-private.json");
    }

    function _key() internal view override returns (uint256) {
        if (block.chainid == ANVIL) return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        return vm.envUint("HOLDER_PRIVATE_KEY");
    }

    function _report(Stack memory s, Verifiers memory v, address escrow, bytes32 registryId) internal {
        console.log("chainId", block.chainid);
        console.log("escrow (operator)", escrow);
        console.log("HumanityRegistry", address(s.registry));
        console.log("accountTree", address(s.accountTree));
        console.log("PrivatePassport", address(s.passport));
        console.log("PrivateReputation", address(s.reputation));
        console.log("PrivateBondVault", address(s.vault));
        console.log("ArbiterRegistry", address(s.panel));

        string memory obj = "private";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "escrow", escrow);
        vm.serializeAddress(obj, "passportDecoder", s.decoder);
        vm.serializeBytes32(obj, "registryId", registryId);
        vm.serializeAddress(obj, "humanityRegistry", address(s.registry));
        vm.serializeAddress(obj, "enrollmentTree", address(s.registry.tree()));
        vm.serializeAddress(obj, "accountTree", address(s.accountTree));
        vm.serializeAddress(obj, "notesTree", address(s.vault.notesTree()));
        vm.serializeAddress(obj, "privatePassport", address(s.passport));
        vm.serializeAddress(obj, "privateReputation", address(s.reputation));
        vm.serializeAddress(obj, "privateBondVault", address(s.vault));
        vm.serializeAddress(obj, "feeRecipient", TREASURY);
        vm.serializeAddress(obj, "sink", SINK);
        vm.serializeAddress(obj, "governor", DAO_GOVERNOR);
        vm.serializeBytes32(obj, "passportId", s.passport.packageId());
        vm.serializeBytes32(obj, "reputationId", s.reputation.packageId());
        vm.serializeBytes32(obj, "bondsId", s.vault.packageId());
        vm.serializeAddress(obj, "panel", address(s.panel));
        vm.serializeBytes32(obj, "panelId", s.panel.packageId());
        vm.serializeAddress(obj, "poolFactory", s.passport.poolFactory());
        vm.serializeAddress(obj, "humanityVerifier", address(v.humanity));
        vm.serializeAddress(obj, "accountVerifier", address(v.account));
        vm.serializeAddress(obj, "bundleVerifier", address(v.bundle));
        vm.serializeAddress(obj, "claimVerifier", address(v.claim));
        vm.serializeAddress(obj, "depositVerifier", address(v.deposit));
        vm.serializeAddress(obj, "reabsorbVerifier", address(v.reabsorb));
        string memory json = vm.serializeAddress(obj, "withdrawVerifier", address(v.withdraw));
        vm.writeJson(json, _out());
        console.log("wrote", _out());
    }
}
