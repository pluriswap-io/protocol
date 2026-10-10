// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {RampIntent, RampQuote} from "../src/ramps/interfaces/IRamp.sol";
import {StargateV2Ramp} from "../src/ramps/StargateV2Ramp.sol";
import {StargateSepolia} from "../src/ramps/StargateSepolia.sol";

/// @dev Arbitrum Sepolia: USDC on the Holder → Core-only deal → ramp Out to Ethereum Sepolia.
contract RampDeal is Script {
    using stdJson for string;

    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 holderPk = _holderKey();
        uint256 providerPk = _providerKey();
        StargateV2Ramp ramp = _deploy(holderPk);
        RampQuote memory q = _quote(ramp, vm.addr(providerPk));
        _fundProvider(holderPk, vm.addr(providerPk), q.nativeFee);
        bytes32 id = _deal(holderPk, providerPk);
        _out(providerPk, ramp, q);
        _write(address(ramp), id, q);
        console.log("ramp", address(ramp));
        console.log("dealId", vm.toString(id));
        console.log("quoteNativeFee", q.nativeFee);
        console.log("quoteAmountOut", q.amountOut);
    }

    function _deploy(uint256 holderPk) internal returns (StargateV2Ramp ramp) {
        vm.startBroadcast(holderPk);
        ramp = new StargateV2Ramp(StargateSepolia.USDC_POOL);
        vm.stopBroadcast();
        require(ramp.token() == StargateSepolia.USDC, "pool token");
    }

    function _quote(StargateV2Ramp ramp, address provider) internal view returns (RampQuote memory q) {
        q = ramp.quote(_intent(provider));
        require(q.amountOut >= 1, "amountOut");
    }

    function _fundProvider(uint256 holderPk, address provider, uint256 nativeFee) internal {
        uint256 need = nativeFee + 0.0005 ether;
        if (provider.balance >= need) return;
        vm.startBroadcast(holderPk);
        (bool ok,) = provider.call{value: need}("");
        require(ok, "fund provider");
        vm.stopBroadcast();
    }

    function _deal(uint256 holderPk, uint256 providerPk) internal returns (bytes32 id) {
        address holder = vm.addr(holderPk);
        address provider = vm.addr(providerPk);
        IERC20 usdc = IERC20(StargateSepolia.USDC);
        Escrow escrow = Escrow(_escrow());
        require(usdc.balanceOf(holder) >= PRINCIPAL, "usdc");

        vm.startBroadcast(holderPk);
        usdc.approve(address(escrow), PRINCIPAL);
        vm.stopBroadcast();

        id = _activate(escrow, holder, provider, holderPk, providerPk);

        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.release(id);
        vm.stopBroadcast();
        require(escrow.status(id) == Status.RELEASED, "released");
        require(usdc.balanceOf(provider) >= PRINCIPAL, "payout");
    }

    function _out(uint256 providerPk, StargateV2Ramp ramp, RampQuote memory q) internal {
        address provider = vm.addr(providerPk);
        IERC20 usdc = IERC20(StargateSepolia.USDC);
        vm.startBroadcast(providerPk);
        usdc.approve(address(ramp), PRINCIPAL);
        ramp.send{value: q.nativeFee + 0.0002 ether}(_intent(provider));
        vm.stopBroadcast();
        require(usdc.balanceOf(address(ramp)) == 0, "ramp empty");
    }

    function _activate(Escrow escrow, address holder, address provider, uint256 holderPk, uint256 providerPk)
        internal
        returns (bytes32 id)
    {
        DealTerms memory terms;
        terms.holder = holder;
        terms.controller = holder;
        terms.provider = provider;
        terms.token = StargateSepolia.USDC;
        terms.principal = PRINCIPAL;
        terms.fiatDuration = 3600;
        terms.releaseDuration = 1800;
        terms.disputeDuration = 7200;
        terms.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        terms.packageIds = new bytes32[](0);

        HolderAuthorization memory ha =
            HolderAuthorization({terms: terms, nonce: 4, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa = ProviderAgreement({terms: terms, nonce: 4, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;

        bytes memory holderSig = _sign(escrow, Consent.hashHolderAuthorization(ha), holderPk);
        bytes memory providerSig = _sign(escrow, Consent.hashProviderAgreement(pa), providerPk);

        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, holderSig, pa, providerSig, ca, "");
        vm.stopBroadcast();
    }

    function _intent(address provider) internal pure returns (RampIntent memory) {
        return RampIntent({
            token: StargateSepolia.USDC,
            amount: PRINCIPAL,
            minAmountOut: 1,
            dest: StargateSepolia.ETHEREUM_SEPOLIA_EID,
            to: provider,
            refund: provider
        });
    }

    function _write(address ramp, bytes32 dealId, RampQuote memory q) internal {
        string memory obj = "ramp";
        vm.serializeUint(obj, "chainId", ARBITRUM_SEPOLIA);
        vm.serializeAddress(obj, "escrow", _escrow());
        vm.serializeAddress(obj, "usdc", StargateSepolia.USDC);
        vm.serializeAddress(obj, "stargatePool", StargateSepolia.USDC_POOL);
        vm.serializeAddress(obj, "ramp", ramp);
        vm.serializeUint(obj, "nativeFee", q.nativeFee);
        vm.serializeUint(obj, "amountOut", q.amountOut);
        vm.serializeUint(obj, "destEid", StargateSepolia.ETHEREUM_SEPOLIA_EID);
        string memory json = vm.serializeBytes32(obj, "releasedDealId", dealId);
        vm.writeJson(json, "deployments/sepolia-ramp.json");
        console.log("wrote deployments/sepolia-ramp.json");
    }

    function _escrow() internal view returns (address) {
        return vm.readFile("deployments/sepolia-packages.json").readAddress(".escrow");
    }

    function _sign(Escrow escrow, bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
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
