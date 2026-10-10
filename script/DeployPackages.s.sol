// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ArbiterRegistry} from "../src/packages/ArbiterRegistry.sol";
import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {PassportPicker} from "./PassportPicker.s.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BondVault} from "../mocks/BondVault.sol";
import {PaymentProof} from "../src/packages/PaymentProof.sol";
import {PaymentVerifierMock} from "../mocks/PaymentVerifierMock.sol";
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";

/// @dev New Sepolia escrow with the full verb list. Does not overwrite deployments/sepolia.json.
///      Test chains only: this stack ships `mocks/` stand-ins for ZK and arbitration and hardcodes placeholder
///      fee/sink/tribunal addresses, so it can never produce a production identity.
contract DeployPackages is PassportPicker {
    using stdJson for string;

    /// @dev The official shares (Anexo R, 2026-09-28): 0.3% from the Holder at activation, 0.3% out of the pot.
    ///      Charged by the kernel itself since 2026-10-02, so the reputation package charges neither.
    uint16 internal constant KERNEL_ACT_BPS = 30;
    uint16 internal constant KERNEL_COMP_BPS = 30;
    uint256 internal constant ACT_BPS = 0;
    uint256 internal constant COMP_BPS = 0;
    uint256 internal constant CONTEST_BPS = 100;
    /// @dev PROTOCOLO.md §E.3.14.6: the official floor is low and global (~2 USDC). The old 10 USDC floor was
    ///      regressive against the T1 cap (250); a per-tier/per-deal floor is not implementable without a
    ///      kernel bump (`contestFloor` is a stateless getter that lives inside the packageId).
    uint256 internal constant CONTEST_FLOOR = 2_000_000;
    uint256 internal constant ZK_FEE = 10_000;
    /// @dev The ARBITRATION package prices its own contest (PROTOCOLO.md §E.3.14.6). Deliberately
    ///      different from CONTEST_FLOOR so an operator watching the lab can tell the two invoices
    ///      apart when a deal carries both packages.
    uint256 internal constant COURT_CONTEST = 500_000;
    uint256 internal constant COURT_FEE = 1_000_000;
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant SINK = address(0xdeaD);
    address internal constant TRIBUNAL = address(0x71B);
    uint256 internal constant PANEL_BOND_SHARE_BPS = 3_000;

    function run() external {
        _requireMockChain("DeployPackages");
        uint256 pk = _key();
        address deployer = vm.addr(pk);
        TestToken token = _token();

        uint64 n = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, n + 6);

        vm.startBroadcast(pk);
        (IPassport passport, address decoder) = _deployPassport();
        Reputation reputation =
            new Reputation(passport, FEE_RECIPIENT, ACT_BPS, COMP_BPS, CONTEST_BPS, CONTEST_FLOOR, predicted);
        PaymentVerifierMock verifier = new PaymentVerifierMock();
        PaymentProof zk = new PaymentProof(predicted, verifier, FEE_RECIPIENT, ZK_FEE, address(0));
        BondVault vault = new BondVault(predicted, SINK, passport);
        ArbitrationMock arb = new ArbitrationMock(
            TRIBUNAL, address(token), COURT_FEE, 1 days, predicted, COURT_CONTEST, FEE_RECIPIENT, 0
        );
        Escrow escrow = new Escrow(FEE_RECIPIENT, KERNEL_ACT_BPS, KERNEL_COMP_BPS);
        // The tribunal the protocol pushes (Anexo R, 2026-09-28): 0.2% availability per arbiter, 10% of the
        // principal locked per arbiter per deal, half of it lost by a lone abstainer, no dispute fee but 30% of the
        // loser's bond (2026-10-05), four days to answer (three to commit, one to reveal), and a 14-day exit for the bond
        // (2026-09-29).
        ArbiterRegistry panel = new ArbiterRegistry(
            address(escrow),
            address(token),
            ArbiterRegistry.Policy(3 days, 1 days, 14 days, 1_000, 5_000, 20, uint16(PANEL_BOND_SHARE_BPS)),
            address(0),
            address(vault),
            address(0),
            address(0),
            bytes32(0),
            address(0)
        );
        vm.stopBroadcast();

        require(address(escrow) == predicted, "escrow prediction");
        require(reputation.operator() == address(escrow), "rep operator");
        require(zk.escrow() == address(escrow), "zk escrow");
        require(vault.operator() == address(escrow), "vault operator");
        require(arb.operator() == address(escrow), "arb operator");

        console.log("chainId", block.chainid);
        console.log("TestToken", address(token));
        console.log("Passport", address(passport));
        console.log("Reputation", address(reputation));
        console.log("BondVault", address(vault));
        console.log("PaymentProof", address(zk));
        console.log("ArbitrationMock", address(arb));
        console.log("Escrow", address(escrow));
        console.log("ArbiterRegistry", address(panel));

        string memory obj = "packages";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        vm.serializeAddress(obj, "passport", address(passport));
        vm.serializeAddress(obj, "passportDecoder", decoder);
        vm.serializeAddress(obj, "reputation", address(reputation));
        vm.serializeAddress(obj, "bondVault", address(vault));
        vm.serializeAddress(obj, "verifier", address(verifier));
        vm.serializeAddress(obj, "zk", address(zk));
        vm.serializeAddress(obj, "arbitration", address(arb));
        vm.serializeAddress(obj, "feeRecipient", FEE_RECIPIENT);
        vm.serializeAddress(obj, "sink", SINK);
        vm.serializeBytes32(obj, "passportId", passport.packageId());
        vm.serializeBytes32(obj, "reputationId", reputation.packageId());
        vm.serializeBytes32(obj, "bondsId", vault.packageId());
        vm.serializeBytes32(obj, "zkId", zk.packageId());
        vm.serializeBytes32(obj, "arbId", arb.packageId());
        vm.serializeAddress(obj, "panel", address(panel));
        vm.serializeBytes32(obj, "panelId", panel.packageId());
        string memory json = vm.serializeAddress(obj, "escrow", address(escrow));
        vm.writeJson(json, _out());
        console.log("wrote", _out());
    }

    function _token() internal view returns (TestToken token) {
        address override_ = vm.envOr("TOKEN", address(0));
        if (override_ != address(0)) return TestToken(override_);
        string memory core = block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia.json"
            : string.concat("deployments/", vm.toString(block.chainid), ".json");
        require(vm.exists(core), core);
        token = TestToken(vm.readFile(core).readAddress(".testToken"));
        require(address(token).code.length > 0, "token");
    }

    function _out() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-packages.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
    }

    function _key() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }
}
