// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Status,
    DealTerms,
    DealClocks,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit,
    PackageMods
} from "../../src/libraries/Types.sol";
import {Consent} from "../../src/libraries/Consent.sol";
import {Escrow} from "../../src/Escrow.sol";

/// @dev Mintable 6-dec stable whose transfers *to* a flagged address revert (blacklist / hook).
///      Lets the handler force the credit-first path on any push without a contract receiver.
contract ToggleRejectToken is ERC20 {
    error Rejected();

    mapping(address account => bool) public rejecting;

    constructor() ERC20("Toggle USD", "GUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRejecting(address who, bool on) external {
        rejecting[who] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (rejecting[to]) revert Rejected();
        super._update(from, to, value);
    }
}

/// @dev Shared plumbing for stateful handlers: actors, EIP-712 signing, ghost deal book, picking.
///      Every verb picks a deal that satisfies its full precondition and is a no-op otherwise, so with
///      `fail_on_revert = true` any revert is a kernel finding, not handler noise.
abstract contract HandlerBase is Test {
    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant PROVIDER_PK = 0xB0B;
    uint256 internal constant CONTROLLER_PK = 0xC0;
    uint256 internal constant MAX_DURATION = 7 days;
    uint256 internal constant MAX_WARP = 2 days;
    uint256 internal constant AUTH_TTL = 1 days;

    uint8 internal constant K_ZK = 8;
    uint8 internal constant K_ARB = 16;

    Escrow public escrow;
    address public holder;
    address public provider;
    address public controller;
    address public relayer = address(0xE1A);

    struct Ghost {
        uint256 principal;
        uint256 holderNonce;
        uint256 providerNonce;
        uint256 controllerNonce;
        bool distinct;
        uint8 kinds;
        address reputation;
        bool terminal;
        Status terminalStatus;
        uint256 holderAmt;
        uint256 providerAmt;
        /// Mapped court ruling of an arbitration terminal (1 Holder wins, 2 Provider wins). Zero when the deal
        /// never went to court. Not derivable from settlement amounts: see `invariant_feesAccounted`.
        uint8 ruling;
    }

    bytes32[] public ids;
    mapping(bytes32 dealId => Ghost) internal ghosts;
    uint256 public nonce;
    uint256 public ghost_minted;
    mapping(bytes32 name => uint256) public calls;

    modifier count(bytes32 name) {
        calls[name]++;
        _;
    }

    constructor(Escrow escrow_) {
        escrow = escrow_;
        holder = vm.addr(HOLDER_PK);
        provider = vm.addr(PROVIDER_PK);
        controller = vm.addr(CONTROLLER_PK);
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function ghostOf(bytes32 id) external view returns (Ghost memory) {
        return ghosts[id];
    }

    // --- time -------------------------------------------------------------------------------------

    function warp(uint256 secs) external count("warp") {
        vm.warp(block.timestamp + bound(secs, 0, MAX_WARP));
    }

    // --- signing ----------------------------------------------------------------------------------

    function _typed(bytes32 structHash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _typed(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _controllerPk(Ghost storage g) internal view returns (uint256) {
        return g.distinct ? CONTROLLER_PK : HOLDER_PK;
    }

    // --- predicates -------------------------------------------------------------------------------

    function _status(bytes32 id) internal view returns (Status) {
        return escrow.status(id);
    }

    function _zk(bytes32 id) internal view returns (bool) {
        return (escrow.kinds(id) & K_ZK) != 0;
    }

    function _arb(bytes32 id) internal view returns (bool) {
        return (escrow.kinds(id) & K_ARB) != 0;
    }

    function _due(uint256 origin, uint256 duration) internal view returns (bool) {
        return block.timestamp >= origin + duration;
    }

    function _releaseDue(bytes32 id) internal view returns (bool) {
        return _due(escrow.clocks(id).fiatSentAt, escrow.terms(id).releaseDuration);
    }

    function _disputeDue(bytes32 id) internal view returns (bool) {
        return _due(escrow.clocks(id).disputedAt, escrow.terms(id).disputeDuration);
    }

    function _isTerminal(Status s) internal pure returns (bool) {
        return s == Status.RELEASED || s == Status.RESOLVED_SPLIT || s == Status.STALEMATE || s == Status.CANCELLED
            || s == Status.RESOLVED_BY_ARBITRATION || s == Status.CLAIMED || s == Status.ABANDONED;
    }

    function _canMarkFiat(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FUNDED && !_zk(id);
    }

    function _canCancelByProvider(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FUNDED;
    }

    function _canTimeoutFiat(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FUNDED && _due(escrow.clocks(id).activatedAt, escrow.terms(id).fiatDuration);
    }

    function _canRelease(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FIAT_SENT;
    }

    function _canClaim(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FIAT_SENT && !_zk(id) && _releaseDue(id);
    }

    function _canOpenDisputed(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FIAT_SENT && !_zk(id) && !_releaseDue(id);
    }

    function _canForceStalemate(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.DISPUTED && _disputeDue(id);
    }

    function _liveActive(bytes32 id) internal view returns (bool) {
        Status s = _status(id);
        return s == Status.FIAT_SENT || s == Status.DISPUTED || s == Status.ARBITRATION_ACTIVE;
    }

    /// @dev Where a split is still an agreement: a live deal nobody has disputed or taken to court (Anexo R,
    ///      2026-09-24 and 2026-09-29).
    function _splittable(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FIAT_SENT;
    }

    function _liveAny(bytes32 id) internal view returns (bool) {
        return _status(id) == Status.FUNDED || _liveActive(id);
    }

    /// Round-robin from `seed` over the ghost book; first deal satisfying `pred`.
    function _pickIf(uint256 seed, function(bytes32) internal view returns (bool) pred)
        internal
        view
        returns (bytes32 id, bool ok)
    {
        uint256 n = ids.length;
        if (n == 0) return (bytes32(0), false);
        uint256 start = seed % n;
        for (uint256 i; i < n; i++) {
            bytes32 c = ids[(start + i) % n];
            if (pred(c)) return (c, true);
        }
    }

    // --- ghost book -------------------------------------------------------------------------------

    function _record(bytes32 id, DealTerms memory t, uint256 hN, uint256 pN, uint256 cN, uint8 kinds, address rep)
        internal
    {
        require(ghosts[id].principal == 0, "dealId collision");
        Ghost storage g = ghosts[id];
        g.principal = t.principal;
        g.holderNonce = hN;
        g.providerNonce = pN;
        g.controllerNonce = cN;
        g.distinct = t.holder != t.controller;
        g.kinds = kinds;
        g.reputation = rep;
        ids.push(id);
    }

    function _recordTerminal(bytes32 id) internal {
        Ghost storage g = ghosts[id];
        if (g.terminal) return;
        (Status s, uint256 h, uint256 p) = escrow.settlementOf(id);
        require(_isTerminal(s), "not terminal after terminal verb");
        g.terminal = true;
        g.terminalStatus = s;
        g.holderAmt = h;
        g.providerAmt = p;
    }

    // --- Core verbs shared by every escrow handler ------------------------------------------------
    // Holder-positive exits from FUNDED and terminals from FIAT_SENT are throttled by `seed` so the
    // book reaches DISPUTED / court / stalemate often enough to matter.

    function markFiat(uint256 seed) external count("markFiat") {
        (bytes32 id, bool ok) = _pickIf(seed, _canMarkFiat);
        if (!ok) return;
        vm.prank(provider);
        escrow.markFiat(id);
    }

    function cancelByProvider(uint256 seed) external count("cancelByProvider") {
        if (seed % 4 != 0) return;
        (bytes32 id, bool ok) = _pickIf(seed, _canCancelByProvider);
        if (!ok) return;
        vm.prank(provider);
        escrow.cancelByProvider(id);
        _recordTerminal(id);
    }

    function timeoutFiat(uint256 seed) external count("timeoutFiat") {
        if (seed % 4 != 0) return;
        (bytes32 id, bool ok) = _pickIf(seed, _canTimeoutFiat);
        if (!ok) return;
        vm.prank(relayer);
        escrow.timeoutFiat(id);
        _recordTerminal(id);
    }

    function release(uint256 seed) external count("release") {
        if (seed % 3 != 0) return;
        (bytes32 id, bool ok) = _pickIf(seed, _canRelease);
        if (!ok) return;
        vm.prank(escrow.terms(id).controller);
        escrow.release(id);
        _recordTerminal(id);
    }

    function claim(uint256 seed) external count("claim") {
        if (seed % 3 != 0) return;
        (bytes32 id, bool ok) = _pickIf(seed, _canClaim);
        if (!ok) return;
        vm.prank(relayer);
        escrow.claim(id);
        _recordTerminal(id);
    }

    function openDisputed(uint256 seed) external virtual count("openDisputed") {
        (bytes32 id, bool ok) = _pickIf(seed, _canOpenDisputed);
        if (!ok) return;
        vm.prank(escrow.terms(id).controller);
        escrow.openDisputed(id);
    }

    function forceDisputeTimeout(uint256 seed) external count("forceDisputeTimeout") {
        (bytes32 id, bool ok) = _pickIf(seed, _canForceStalemate);
        if (!ok) return;
        vm.prank(relayer);
        escrow.forceDisputeTimeout(id);
        _recordTerminal(id);
    }

    function mutualCancel(uint256 seed) external count("mutualCancel") {
        (bytes32 id, bool ok) = seed % 4 == 0 ? _pickIf(seed, _liveAny) : _pickIf(seed, _liveActive);
        if (!ok) return;
        Ghost storage g = ghosts[id];
        uint256 deadline = block.timestamp + AUTH_TTL;
        MutualCancel memory p = MutualCancel({dealId: id, nonce: ++nonce, deadline: deadline});
        MutualCancel memory c = MutualCancel({dealId: id, nonce: ++nonce, deadline: deadline});
        vm.prank(relayer);
        escrow.mutualCancel(
            p, _sign(PROVIDER_PK, Consent.hashMutualCancel(p)), c, _sign(_controllerPk(g), Consent.hashMutualCancel(c))
        );
        _recordTerminal(id);
    }

    function coSignedRelease(uint256 seed) external count("coSignedRelease") {
        if (seed % 3 != 0) return;
        (bytes32 id, bool ok) = _pickIf(seed, _liveActive);
        if (!ok) return;
        Ghost storage g = ghosts[id];
        uint256 deadline = block.timestamp + AUTH_TTL;
        CoSignedRelease memory p = CoSignedRelease({dealId: id, nonce: ++nonce, deadline: deadline});
        CoSignedRelease memory c = CoSignedRelease({dealId: id, nonce: ++nonce, deadline: deadline});
        vm.prank(relayer);
        escrow.coSignedRelease(
            p,
            _sign(PROVIDER_PK, Consent.hashCoSignedRelease(p)),
            c,
            _sign(_controllerPk(g), Consent.hashCoSignedRelease(c))
        );
        _recordTerminal(id);
    }

    function mutualSplit(uint256 seed, uint16 bps) external count("mutualSplit") {
        if (seed % 3 != 0) return;
        (bytes32 id, bool ok) = _pickIf(seed, _splittable);
        if (!ok) return;
        bps = uint16(bound(bps, 0, 10_000));
        Ghost storage g = ghosts[id];
        uint256 deadline = block.timestamp + AUTH_TTL;
        MutualSplit memory p = MutualSplit({dealId: id, providerBps: bps, nonce: ++nonce, deadline: deadline});
        MutualSplit memory c = MutualSplit({dealId: id, providerBps: bps, nonce: ++nonce, deadline: deadline});
        vm.prank(relayer);
        escrow.mutualSplit(
            p, _sign(PROVIDER_PK, Consent.hashMutualSplit(p)), c, _sign(_controllerPk(g), Consent.hashMutualSplit(c))
        );
        _recordTerminal(id);
    }

    // --- activation -------------------------------------------------------------------------------

    function _baseTerms(uint256 principal, bool distinct, uint256 fiatDur, uint256 relDur, uint256 dispDur)
        internal
        view
        returns (DealTerms memory t)
    {
        t.holder = holder;
        t.controller = distinct ? controller : holder;
        t.provider = provider;
        t.principal = principal;
        t.fiatDuration = bound(fiatDur, 0, MAX_DURATION);
        t.releaseDuration = bound(relDur, 0, MAX_DURATION);
        t.disputeDuration = bound(dispDur, 0, MAX_DURATION);
        t.fiatCommit = bytes32(uint256(keccak256("fiat leg")) >> 8); // opaque to the kernel; a field element, as any Poseidon output is
        t.arbitrationDuration = t.disputeDuration;
        t.packageIds = new bytes32[](0);
    }

    function _activateSigned(DealTerms memory t, uint8 kinds, address rep, PackageMods memory mods, bool packaged)
        internal
        returns (bytes32 id)
    {
        bool distinct = t.holder != t.controller;
        uint256 hN = ++nonce;
        uint256 pN = ++nonce;
        uint256 cN = distinct ? ++nonce : 0;
        uint256 deadline = block.timestamp + AUTH_TTL;
        HolderAuthorization memory ha = HolderAuthorization({terms: t, nonce: hN, deadline: deadline});
        ProviderAgreement memory pa = ProviderAgreement({terms: t, nonce: pN, deadline: deadline});
        ControllerAcceptance memory ca;
        bytes memory cs;
        if (distinct) {
            ca = ControllerAcceptance({terms: t, nonce: cN, deadline: deadline});
            cs = _sign(CONTROLLER_PK, Consent.hashControllerAcceptance(ca));
        }
        bytes memory hs = _sign(HOLDER_PK, Consent.hashHolderAuthorization(ha));
        bytes memory ps = _sign(PROVIDER_PK, Consent.hashProviderAgreement(pa));
        vm.prank(relayer);
        if (packaged) {
            id = escrow.activate(ha, hs, pa, ps, ca, cs, mods);
        } else {
            id = escrow.activate(ha, hs, pa, ps, ca, cs);
        }
        _record(id, t, hN, pN, cN, kinds, rep);
    }
}
