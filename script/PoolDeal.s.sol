// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    PackageMods,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";

/// @dev Deploy factory + private share pool, then authorize → activate → markFiat → release → reconcile.
contract PoolDeal is Script {
    using stdJson for string;

    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant HOLDER_NONCE = 884210;
    uint256 internal constant PROVIDER_NONCE = 884211;
    uint256 internal constant CONTROLLER_NONCE = 884212;

    /// This script demos a Core-only pool deal (`packageIds` is empty), so every package slot is zero.
    /// `Pool.authorize` runs `Packages.resolve`, which would reject these mods against any signed id.
    function _noMods() internal pure returns (PackageMods memory m) {}

    function run() external {
        uint256 holderPk = _holderKey();
        uint256 providerPk = _providerKey();
        address owner = vm.addr(holderPk);
        address provider = vm.addr(providerPk);
        address controller = owner;

        (TestToken token, Escrow escrow) = _core();
        require(address(escrow).code.length > 0, "escrow");

        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.005 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }

        address[] memory sponsors = new address[](1);
        sponsors[0] = owner;
        // A Sponsor is already an agent (§E.3.16.1), and `initialize` rejects one that is ALSO listed
        // as designated. This demo's controller is the sponsor, so the designated roster is empty.
        address[] memory cs = new address[](0);
        address[] memory depositors = new address[](1);
        depositors[0] = owner;

        vm.startBroadcast(holderPk);
        PoolFactory factory = new PoolFactory(address(escrow));
        vm.stopBroadcast();

        // The pool is the Holder: it pays the kernel's activation share on top of the principal, and the
        // Provider is paid net of the completion share.
        uint256 actFee = PRINCIPAL * escrow.activationBps() / 10_000;
        uint256 compFee = PRINCIPAL * escrow.completionBps() / 10_000;

        vm.startBroadcast(holderPk);
        Pool pool = Pool(factory.createPool(sponsors, address(token), cs, false, depositors, 0));
        token.mint(owner, PRINCIPAL + actFee);
        token.approve(address(pool), PRINCIPAL + actFee);
        pool.deposit(PRINCIPAL + actFee);

        DealTerms memory terms = _terms(address(pool), controller, provider, address(token));
        HolderAuthorization memory ha =
            HolderAuthorization({terms: terms, nonce: HOLDER_NONCE, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa =
            ProviderAgreement({terms: terms, nonce: PROVIDER_NONCE, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca =
            ControllerAcceptance({terms: terms, nonce: CONTROLLER_NONCE, deadline: block.timestamp + 1 days});

        pool.authorize(ha, _noMods());
        bytes32 id = escrow.activate(
            ha,
            "",
            pa,
            _sign(escrow, Consent.hashProviderAgreement(pa), providerPk),
            ca,
            _sign(escrow, Consent.hashControllerAcceptance(ca), holderPk)
        );
        vm.stopBroadcast();

        require(escrow.status(id) == Status.FUNDED, "funded");
        require(token.balanceOf(address(escrow)) >= PRINCIPAL, "pulled");

        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();

        vm.startBroadcast(holderPk);
        escrow.release(id);
        pool.reconcile(HOLDER_NONCE);
        vm.stopBroadcast();

        require(escrow.status(id) == Status.RELEASED, "released");
        require(token.balanceOf(provider) >= PRINCIPAL - compFee, "provider payout");
        require(pool.idle() == 0 && pool.locked() == 0, "treasury");
        require(pool.consumed() == PRINCIPAL + actFee, "consumed");
        require(factory.isOfficial(address(pool)), "official");

        console.log("factory", address(factory));
        console.log("implementation", factory.implementation());
        console.log("pool", address(pool));
        console.log("dealId", vm.toString(id));
        console.log("status", uint256(escrow.status(id)));
        console.log("consumed", pool.consumed());

        string memory obj = "poolDeal";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "testToken", address(token));
        vm.serializeAddress(obj, "escrow", address(escrow));
        vm.serializeAddress(obj, "factory", address(factory));
        vm.serializeAddress(obj, "implementation", factory.implementation());
        vm.serializeBytes32(obj, "officialCodehash", factory.officialCodehash());
        vm.serializeAddress(obj, "pool", address(pool));
        vm.serializeAddress(obj, "owner", owner);
        vm.serializeAddress(obj, "controller", controller);
        string memory json = vm.serializeBytes32(obj, "releasedDealId", id);
        vm.writeJson(json, _out());
        console.log("wrote", _out());
    }

    function _terms(address pool, address controller, address provider, address token)
        internal
        pure
        returns (DealTerms memory t)
    {
        t.holder = pool;
        t.controller = controller;
        t.provider = provider;
        t.token = token;
        t.principal = PRINCIPAL;
        t.fiatDuration = 3600;
        t.releaseDuration = 1800;
        t.disputeDuration = 7200;
        t.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        t.packageIds = new bytes32[](0);
    }

    function _core() internal view returns (TestToken token, Escrow escrow) {
        string memory json = vm.readFile(_corePath());
        token = TestToken(json.readAddress(".testToken"));
        escrow = Escrow(json.readAddress(".escrow"));
    }

    function _corePath() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia.json";
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function _out() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-pool.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-pool.json");
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
