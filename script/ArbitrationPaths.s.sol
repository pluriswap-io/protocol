// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
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
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BondVault} from "../mocks/BondVault.sol";

/// @title ArbitrationPaths
/// @notice The terminals that only a tribunal can reach, walked on chain with bonds posted.
/// @dev `Paths` covers the twelve Core terminals and the ladder covers the reputation curve. What
///      neither could reach is everything downstream of a verdict, because Core has no tribunal:
///      the two slashes, the two stalemates, and what an abandoned dispute does when there are bonds
///      on the table. This closes that, against `ArbitrationMock` — not a real court, deliberately. The
///      mock renders any verdict on demand, which is the only way to exercise a losing ruling and a
///      refusal in the same run; a real court cannot be asked to lose on cue. What is being checked
///      is the KERNEL's map from a verdict to money, and that map does not know which court spoke.
///
///      Five deals, five terminals, and the four things worth asserting about each: who got the
///      principal, where each bond lock went, what the score did, and whether the contest was
///      charged. §E.3.11 OUT-09..12 and OUT-14, §E.3.14.5, §E.3.14.7.
///
///      Usage: `forge script script/ArbitrationPaths.s.sol:ArbitrationPaths --rpc-url $RPC --broadcast`
contract ArbitrationPaths is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant PRINCIPAL = 250e6; // the T1 cap: every deal here is one tier's worth
    uint256 internal constant BOND = PRINCIPAL / 10; // §E.3.14.5: 10% per side, per deal

    TestToken internal token;
    Escrow internal escrow;
    PassportMock internal passport;
    Reputation internal rep;
    BondVault internal vault;
    ArbitrationMock internal court;

    bytes32 internal SUB_H;
    bytes32 internal SUB_P;
    uint256 internal holderPk;
    uint256 internal providerPk;
    address internal holder;
    address internal provider;
    uint256 internal nonce;

    function run() external {
        _load();
        uint256 salt = vm.envOr("ARB_RUN", block.timestamp);
        SUB_H = keccak256(abi.encodePacked("arb-holder", salt));
        SUB_P = keccak256(abi.encodePacked("arb-provider", salt));
        nonce = uint256(keccak256(abi.encodePacked("arb-nonce", salt)));
        holderPk = _key(false);
        providerPk = _key(true);
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        _prepare();

        _holderWins();
        _providerWins();
        _courtRefuses();
        _courtNeverAnswers();
        _abandonedWithBonds();

        console.log("");
        console.log("arbitration paths: 5 terminals, all asserted");
    }

    /// OUT-09. A refund, so no completion fee; the loser's lock pays the winner's SIGNING address.
    function _holderWins() internal {
        console.log("");
        console.log("ruling 1 - holder wins");
        bytes32 id = _openCourt(1 days);
        _rule(id, ArbitrationMock.Ruling.HolderWin);
        uint256 hBefore = token.balanceOf(holder);
        (, uint32 penPBefore,) = rep.stats(SUB_P, address(token));
        vm.startBroadcast(holderPk);
        escrow.readRuling(id);
        vm.stopBroadcast();

        (Status st, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        require(st == Status.RESOLVED_BY_ARBITRATION, "status");
        require(hAmt == PRINCIPAL && pAmt == 0, "a refund is not a trade: no completion fee");
        // The Provider's lock moved to the Holder; the Holder's own lock came back as available.
        require(token.balanceOf(holder) == hBefore + PRINCIPAL + BOND, "principal + slashed bond");
        require(vault.lockOf(SUB_H, id) == 0 && vault.lockOf(SUB_P, id) == 0, "both locks disposed");
        (, uint32 penP,) = rep.stats(SUB_P, address(token));
        require(penP == penPBefore + 15, "the loser carries 15");
        console.log("  principal + the loser's bond to the Holder; loser penalty +15");
        _scores();
    }

    /// OUT-10. A payout IS a trade, so the completion fee applies; the slash runs the other way.
    function _providerWins() internal {
        console.log("");
        console.log("ruling 2 - provider wins");
        bytes32 id = _openCourt(1 days);
        _rule(id, ArbitrationMock.Ruling.ProviderWin);
        uint256 pBefore = token.balanceOf(provider);
        vm.startBroadcast(holderPk);
        escrow.readRuling(id);
        vm.stopBroadcast();

        (Status st, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        require(st == Status.RESOLVED_BY_ARBITRATION, "status");
        require(hAmt == 0 && pAmt > 0 && pAmt <= PRINCIPAL, "provider gross, completion fee taken");
        require(token.balanceOf(provider) == pBefore + pAmt + BOND, "payout + slashed bond");
        (, uint32 penH,) = rep.stats(SUB_H, address(token));
        require(penH >= 15, "the loser carries 15");
        console.log("  payout + the loser's bond to the Provider; completion fee charged");
        _scores();
    }

    /// OUT-11. The tribunal was asked and would not decide: 50/50, and nothing burns — the bonds come
    /// back, because nobody abandoned anything. Both sides record it.
    function _courtRefuses() internal {
        console.log("");
        console.log("ruling 3 - the court refuses to decide");
        bytes32 id = _openCourt(1 days);
        _rule(id, ArbitrationMock.Ruling.Stalemate);
        (, uint32 penHBefore,) = rep.stats(SUB_H, address(token));
        uint256 availBefore = vault.available(SUB_H, address(token));
        vm.startBroadcast(holderPk);
        escrow.readRuling(id);
        vm.stopBroadcast();

        (Status st, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        require(st == Status.STALEMATE, "status");
        require(hAmt == PRINCIPAL / 2 && pAmt == PRINCIPAL / 2, "50/50, no completion fee");
        require(vault.available(SUB_H, address(token)) == availBefore + BOND, "the lock came back");
        (, uint32 penH,) = rep.stats(SUB_H, address(token));
        require(penH == penHBefore + 5, "a refused tribunal marks both sides");
        console.log("  50/50, bonds returned, +5 to both");
        _scores();
    }

    /// OUT-12. The court never answered. Since 2026-09-29 that is the rare case of an unopenable court and
    /// follows the no-tribunal branch: the principal burned, both locks to the sink, +10 to both. Stretching
    /// a court to its clock no longer buys a clean half.
    function _courtNeverAnswers() internal {
        console.log("");
        console.log("no ruling - the arbitration clock runs out");
        bytes32 id = _openCourt(0); // arbitrationDuration 0: due in the block the court opened
        (, uint32 penHBefore,) = rep.stats(SUB_H, address(token));
        (, uint32 penPBefore,) = rep.stats(SUB_P, address(token));
        uint256 burnBefore = token.balanceOf(BURN);
        vm.startBroadcast(holderPk);
        escrow.forceArbitrationTimeout(id);
        vm.stopBroadcast();

        (Status st, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        require(st == Status.STALEMATE, "status");
        require(hAmt == 0 && pAmt == 0, "a deadlock pays nobody");
        require(token.balanceOf(BURN) >= burnBefore + PRINCIPAL, "the principal burned");
        (, uint32 penH,) = rep.stats(SUB_H, address(token));
        (, uint32 penP,) = rep.stats(SUB_P, address(token));
        require(penH == penHBefore + 10 && penP == penPBefore + 10, "a deadlock marks both");
        require(vault.lockOf(SUB_H, id) == 0 && vault.lockOf(SUB_P, id) == 0, "locks gone to the sink");
        console.log("  principal burned, both bonds to the sink, +10 to both - the no-tribunal branch");
        _scores();
    }

    /// OUT-14 with collateral on the table, in a deal WITH a tribunal: the opener had a court and walked
    /// away, so the Provider takes the pot -- but the bonds still come back, because abandonment is
    /// assumed fault, not proven fault. (Without a tribunal the same timeout is a deadlock: Paths 15.)
    function _abandonedWithBonds() internal {
        console.log("");
        console.log("abandoned dispute, with bonds posted");
        bytes32 id = _activate(3600, 100, 0, 1 days);
        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
        uint256 sinkBefore = token.balanceOf(vault.sink());
        uint256 availBefore = vault.available(SUB_H, address(token));
        (, uint32 penHBefore,) = rep.stats(SUB_H, address(token));
        vm.startBroadcast(holderPk);
        escrow.openDisputed(id);
        escrow.forceDisputeTimeout(id);
        vm.stopBroadcast();

        (Status st, uint256 hAmt, uint256 pAmt) = escrow.settlementOf(id);
        require(st == Status.ABANDONED, "status");
        require(hAmt == 0 && pAmt > 0, "the whole pot to the Provider");
        require(token.balanceOf(vault.sink()) == sinkBefore, "nothing burns: this terminal has a loser");
        require(vault.available(SUB_H, address(token)) == availBefore + BOND, "the opener's bond came back");
        (, uint32 penH,) = rep.stats(SUB_H, address(token));
        require(penH == penHBefore + 5, "the opener carries 5");
        console.log("  pot to the Provider, both bonds returned, opener +5, sink untouched");
        _scores();
    }

    // ---------------------------------------------------------------- plumbing

    function _scores() internal view {
        console.log("    holder score", rep.score(SUB_H, address(token)));
        console.log("    provider score", rep.score(SUB_P, address(token)));
    }

    function _openCourt(uint256 arbDuration) internal returns (bytes32 id) {
        id = _activate(3600, 1800, 7200, arbDuration);
        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.openCourt(id); // charges the contest once, from the opener's wallet
        vm.stopBroadcast();
        require(escrow.status(id) == Status.ARBITRATION_ACTIVE, "court open");
        require(escrow.contestPaid(id), "contest charged");
    }

    function _rule(bytes32 id, ArbitrationMock.Ruling r) internal {
        vm.startBroadcast(holderPk);
        court.submitRuling(id, r); // the mock is a lab tool: anyone renders any verdict
        vm.stopBroadcast();
    }

    function _terms(uint256 fiatD, uint256 releaseD, uint256 disputeD, uint256 arbD)
        internal
        view
        returns (DealTerms memory t)
    {
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = address(token);
        t.principal = PRINCIPAL;
        t.fiatDuration = fiatD;
        t.releaseDuration = releaseD;
        t.disputeDuration = disputeD;
        t.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        t.arbitrationDuration = arbD;
        t.packageIds = _sorted4(passport.packageId(), rep.packageId(), vault.packageId(), court.packageId());
    }

    function _mods() internal view returns (PackageMods memory mods) {
        mods.passport = address(passport);
        mods.reputation = address(rep);
        mods.bonds = address(vault);
        mods.court = address(court);
    }

    function _activate(uint256 fiatD, uint256 releaseD, uint256 disputeD, uint256 arbD) internal returns (bytes32 id) {
        DealTerms memory t = _terms(fiatD, releaseD, disputeD, arbD);
        uint256 n = nonce++;
        HolderAuthorization memory ha = HolderAuthorization(t, n, block.timestamp + 1 days);
        ProviderAgreement memory pa = ProviderAgreement(t, n, block.timestamp + 1 days);
        bytes memory hs = _sign(Consent.hashHolderAuthorization(ha), holderPk);
        bytes memory ps = _sign(Consent.hashProviderAgreement(pa), providerPk);
        ControllerAcceptance memory ca;
        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, hs, pa, ps, ca, "", _mods());
        vm.stopBroadcast();
    }

    function _prepare() internal {
        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.01 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }
        vm.startBroadcast(holderPk);
        token.mint(holder, 100_000e6);
        token.mint(provider, 10_000e6);
        token.approve(address(escrow), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(court), type(uint256).max); // the mock pulls its court fee in ERC-20
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        vault.deposit(SUB_H, address(token), 1_000e6);
        vm.stopBroadcast();
        vm.startBroadcast(providerPk);
        token.approve(address(escrow), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(SUB_P, address(token), 1_000e6);
        vm.stopBroadcast();
    }

    function _sign(bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", escrow.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sorted4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory ids) {
        bytes32[4] memory xs = [a, b, c, d];
        for (uint256 i; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                if (xs[j] < xs[i]) (xs[i], xs[j]) = (xs[j], xs[i]);
            }
        }
        ids = new bytes32[](4);
        for (uint256 i; i < 4; i++) {
            ids[i] = xs[i];
        }
    }

    function _load() internal {
        string memory path = block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia-packages.json"
            : string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
        require(vm.exists(path), path);
        string memory json = vm.readFile(path);
        token = TestToken(json.readAddress(".testToken"));
        escrow = Escrow(json.readAddress(".escrow"));
        passport = PassportMock(json.readAddress(".passport"));
        rep = Reputation(json.readAddress(".reputation"));
        vault = BondVault(json.readAddress(".bondVault"));
        court = ArbitrationMock(json.readAddress(".arbitration"));
        require(address(escrow).code.length > 0, "escrow");
    }

    function _key(bool isProvider) internal view returns (uint256) {
        if (block.chainid == 31337) {
            return isProvider
                ? 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
                : 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        return vm.envUint(isProvider ? "PROVIDER_PRIVATE_KEY" : "HOLDER_PRIVATE_KEY");
    }
}
