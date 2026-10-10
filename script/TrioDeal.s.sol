// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BondVault} from "../mocks/BondVault.sol";

/// @dev One P2P trio deal: activate → markFiat → release.
/// @dev Kept in small functions: a single large `run()` plus a wide tuple return
///      trips a solc 0.8.28 via-ir codegen crash ("1 too deep in the stack").
contract TrioDeal is Script {
    using stdJson for string;

    uint256 internal constant PRINCIPAL = 1_000_000;
    /// @dev What the kernel's official shares (0.3% + 0.3%, `DeployPackages`) charge on this deal's principal.
    uint256 internal constant ACT_FEE = PRINCIPAL * 30 / 10_000;
    uint256 internal constant COMP_FEE = PRINCIPAL * 30 / 10_000;
    uint256 internal constant BOND = PRINCIPAL / 10;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    bytes32 internal constant SUB_H = keccak256("sepolia-holder");
    bytes32 internal constant SUB_P = keccak256("sepolia-provider");

    TestToken internal token;
    Escrow internal escrow;
    PassportMock internal passport;
    Reputation internal reputation;
    BondVault internal vault;
    address internal feeRecipient;

    function run() external {
        _load();
        uint256 holderPk = _holderKey();
        uint256 providerPk = _providerKey();
        address holder = vm.addr(holderPk);
        address provider = vm.addr(providerPk);

        _fund(holderPk, providerPk, holder, provider);
        bytes32 id = _activate(holder, provider, holderPk, providerPk);
        _close(id, providerPk, holderPk);
        _assertOutcomes(id);
        console.log("dealId", vm.toString(id));
        console.log("status", uint256(escrow.status(id)));
        console.log("provider", token.balanceOf(provider));
        console.log("feeRecipient", token.balanceOf(feeRecipient));
        console.log("scoreH", reputation.score(SUB_H, address(token)));
        _writeJson(id);
        console.log("wrote", _path());
    }

    function _fund(uint256 holderPk, uint256 providerPk, address holder, address provider) internal {
        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.005 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }

        vm.startBroadcast(holderPk);
        token.mint(holder, PRINCIPAL + ACT_FEE + BOND);
        token.mint(provider, BOND);
        token.approve(address(escrow), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        vault.deposit(SUB_H, address(token), BOND);
        vm.stopBroadcast();

        vm.startBroadcast(providerPk);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(SUB_P, address(token), BOND);
        vm.stopBroadcast();
    }

    function _activate(address holder, address provider, uint256 holderPk, uint256 providerPk)
        internal
        returns (bytes32 id)
    {
        DealTerms memory terms;
        terms.holder = holder;
        terms.controller = holder;
        terms.provider = provider;
        terms.token = address(token);
        terms.principal = PRINCIPAL;
        terms.fiatDuration = 3600;
        terms.releaseDuration = 1800;
        terms.disputeDuration = 7200;
        terms.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        terms.packageIds = _sorted3(passport.packageId(), reputation.packageId(), vault.packageId());

        HolderAuthorization memory ha =
            HolderAuthorization({terms: terms, nonce: 1, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa = ProviderAgreement({terms: terms, nonce: 1, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(reputation);
        mods.bonds = address(vault);

        bytes memory holderSig = _sign(Consent.hashHolderAuthorization(ha), holderPk);
        bytes memory providerSig = _sign(Consent.hashProviderAgreement(pa), providerPk);

        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, holderSig, pa, providerSig, ca, "", mods);
        vm.stopBroadcast();
    }

    function _close(bytes32 id, uint256 providerPk, uint256 holderPk) internal {
        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.release(id);
        // The kernel accrues its fee; anyone delivers it to the recipient.
        escrow.sweepFees(address(token));
        vm.stopBroadcast();
    }

    function _assertOutcomes(bytes32 id) internal view {
        require(escrow.status(id) == Status.RELEASED, "released");
        require(token.balanceOf(feeRecipient) >= ACT_FEE + COMP_FEE, "fees");
        require(vault.lockOf(SUB_H, id) == 0 && vault.lockOf(SUB_P, id) == 0, "unlocked");
        require(reputation.inFlight(SUB_H, address(token)) == 0, "inFlight");
    }

    function _writeJson(bytes32 id) internal {
        string memory catalog = vm.readFile(_path());
        string memory obj = "packages";
        vm.serializeUint(obj, "chainId", catalog.readUint(".chainId"));
        vm.serializeAddress(obj, "testToken", catalog.readAddress(".testToken"));
        vm.serializeAddress(obj, "passport", catalog.readAddress(".passport"));
        vm.serializeAddress(obj, "reputation", catalog.readAddress(".reputation"));
        vm.serializeAddress(obj, "bondVault", catalog.readAddress(".bondVault"));
        vm.serializeAddress(obj, "verifier", catalog.readAddress(".verifier"));
        vm.serializeAddress(obj, "zk", catalog.readAddress(".zk"));
        vm.serializeAddress(obj, "arbitration", catalog.readAddress(".arbitration"));
        vm.serializeAddress(obj, "feeRecipient", catalog.readAddress(".feeRecipient"));
        vm.serializeAddress(obj, "sink", catalog.readAddress(".sink"));
        vm.serializeAddress(obj, "escrow", catalog.readAddress(".escrow"));
        vm.serializeBytes32(obj, "passportId", catalog.readBytes32(".passportId"));
        vm.serializeBytes32(obj, "reputationId", catalog.readBytes32(".reputationId"));
        vm.serializeBytes32(obj, "bondsId", catalog.readBytes32(".bondsId"));
        vm.serializeBytes32(obj, "zkId", catalog.readBytes32(".zkId"));
        vm.serializeBytes32(obj, "arbId", catalog.readBytes32(".arbId"));
        // Carry the panel through: this rewrite owns only its own keys.
        if (vm.keyExistsJson(catalog, ".panel")) {
            vm.serializeAddress(obj, "panel", catalog.readAddress(".panel"));
            vm.serializeBytes32(obj, "panelId", catalog.readBytes32(".panelId"));
        }
        string memory json = vm.serializeBytes32(obj, "releasedDealId", id);
        vm.writeJson(json, _path());
    }

    function _load() internal {
        string memory path = _path();
        require(vm.exists(path), path);
        string memory json = vm.readFile(path);
        token = TestToken(json.readAddress(".testToken"));
        escrow = Escrow(json.readAddress(".escrow"));
        passport = PassportMock(json.readAddress(".passport"));
        reputation = Reputation(json.readAddress(".reputation"));
        vault = BondVault(json.readAddress(".bondVault"));
        feeRecipient = json.readAddress(".feeRecipient");
        require(address(escrow).code.length > 0, "escrow");
    }

    function _sorted3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory ids) {
        bytes32[3] memory xs = [a, b, c];
        for (uint256 i; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (xs[j] < xs[i]) (xs[i], xs[j]) = (xs[j], xs[i]);
            }
        }
        ids = new bytes32[](3);
        ids[0] = xs[0];
        ids[1] = xs[1];
        ids[2] = xs[2];
    }

    function _sign(bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-packages.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
    }

    function _holderKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }

    function _providerKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }
        pk = vm.envUint("PROVIDER_PRIVATE_KEY");
    }
}
