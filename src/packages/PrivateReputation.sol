// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Governed} from "./Governed.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IReputation} from "./interfaces/IReputation.sol";
import {IAccountVerifier} from "./interfaces/IAccountVerifier.sol";
import {IClaimVerifier} from "./interfaces/IClaimVerifier.sol";
import {IBundleVerifier} from "./interfaces/IBundleVerifier.sol";
import {IPrivatePassport} from "./interfaces/IPrivatePassport.sol";
import {IPrivateReputation} from "./interfaces/IPrivateReputation.sol";
import {PoseidonTree} from "./PoseidonTree.sol";
import {VouchData} from "./libraries/VouchData.sol";
import {Tiers} from "./libraries/Tiers.sol";

/// @title PrivateReputation
/// @notice Hidden-account package: registers accounts, carries the activation edge and the terminal
///         delta of the private world (PROTOCOLO.md §E.3.15.3–E.3.15.5), behind the kernel's `IReputation`.
/// @dev The account IS the leaf: nothing here can read a balance, a tier or a history — the contract
///      only manages the tree, the nullifiers and the pending deltas. The cap
///      arithmetic (`inFlight + principal <= cap`, tier in-circuit) is proven by `prepare_side`, not
///      checked here. It also carries the fee policy, because the kernel binds a reputation package
///      to `PackageId.reputation(module, fee policy)`: a different fee is a different package.
///
///      Flow (PROTOCOLO.md §E.3.15.4–E.3.15.5):
///      * `admit` (kernel, operator-only, inside `Escrow.activate`): receives the side's proven inputs
///        as the opaque package data the kernel forwards (Anexo R, 2026-09-29) — there is no
///        `prepare`, so a proof has nowhere to execute without an activation. It matches the deal,
///        token and principal, asks the shared verifier whether exactly these inputs were proven in
///        this transaction, burns `nullRep(v)` (which serializes two activations against the same
///        account version) and, on the second side, inserts both leaves together. A failed activation
///        reverts all of it with the tx.
///      * `notifyTerminal` (kernel, operator-only, try/retry): writes `pending[subject] = (kind,
///        principal, token)` and nothing else — the subject is the kernel's per-deal snapshot, so
///        records cannot collide across deals. A second record for the same subject fails closed
///        (the same human on both ends of one deal is pathological; the account punishes itself).
///      * `claim` (user or relayer, proof-gated): applies the terminal delta — verifies the binding
///        `dealSubject = Poseidon(sk_id, dealId)`, membership of the current leaf and the delta
///        arithmetic in-circuit — burns `nullRep(v)`, inserts the delta leaf, marks `claimed`. The
///        delta is atomic (§E.3.15.5): not claiming the penalty means never releasing the inFlight.
///      `admit` accepts at most one vault: the bound `bondsVault` of the deployment (§E.3.15.6) — a
///      counterparty signs a BONDS deal trusting that the lock exists, so a foreign vault under
///      this same reputation is refused. The bond column of the cap is proven in-circuit by
///      `prepare_side` (with `lockCommit`); the lock itself is `reserve`'s to enforce, in the vault.
///
///      Open accounts (2026-10-01): an account may exist WITHOUT a proof of humanity (`registerOpen`). It trades
///      like any other, under the same tree and the same proofs, and its leaf says `verified = 0`. What it
///      cannot do is credit or be credited: a completed deal lands in the public RECORD of both sides
///      (`rec_count`, `rec_volume` — what the listing shows), and in the CREDIT that buys tier only when both
///      sides were verified when it activated (`creditable[dealId]`, written once by `admit`, read by every
///      `claim`). Penalties land either way. It cannot carry a bond either, and it may verify later in place
///      (`upgrade`), keeping everything it has — record, penalties, counterparty tree — and crediting from
///      then on. Free accounts that could credit would let N throwaway accounts climb a verified one's tier
///      for the price of the fees; the ladder is priced in humans, which is where the Passport bites.
///
///      Pools (Anexo R, 2026-10-05): a pool is a peer. Its account is public — a business's record — and climbs
///      the same ladder in the clear (`poolScore`, `poolCap`): a concurrent cap from T1 up, the bond column while
///      its own lock backs every open deal, credit once per distinct Provider and sixteen per epoch, the same
///      penalties. Its side is always the vouch of its operator, the deal's Controller, a verified human.
///      A mock behind any of the verifier interfaces is not privacy.
contract PrivateReputation is IReputation, IPrivateReputation, Governed {
    /// @dev Account tree depth, PROTOCOLO.md §E.3.15.3. Enforced at construction: a private reputation
    ///      is only ever wired to a depth-32 accounts tree (depth 20 is the notes tree of F3).
    uint256 public constant TREE_DEPTH = 32;

    /// @dev The terminal delta owed to a deal subject, as the kernel reported it (PROTOCOLO.md §E.3.15.5).
    struct Pending {
        IReputation.Close kind;
        address token;
        uint256 principal;
    }

    IPassport public immutable passport;
    PoseidonTree public immutable accountTree;
    IAccountVerifier public immutable accountVerifier;
    /// @dev The shared verifier of §E.3.15.4. Immutable, and the module's address is its `packageId`:
    ///      consenting to the package is consenting to this verifier.
    IBundleVerifier public immutable bundleVerifier;
    IClaimVerifier public immutable claimVerifier;
    address public immutable feeRecipient;

    /// @dev The fees this module names in its `packageId` (Anexo R, 2026-10-06): what the DAO may change, inside the
    ///      bounds below, for the deals not yet activated. The kernel copies them at activation and charges a live deal
    ///      those, never these. `contestFloor` is in raw units of the deal's token.
    struct Fees {
        uint16 activationBps;
        uint16 completionBps;
        uint16 contestBps;
        uint128 contestFloor;
    }

    uint16 public constant MAX_ACTIVATION_BPS = 100;
    uint16 public constant MAX_COMPLETION_BPS = 100;
    uint16 public constant MAX_CONTEST_BPS = 300;
    /// @dev Ten whole tokens of a six-decimal stablecoin.
    uint128 public constant MAX_CONTEST_FLOOR = 10_000_000;

    Fees internal _fees;
    address public immutable operator;
    /// @dev The private vault this reputation admits (F3 binding, §E.3.15.6). Zero in a vault-less
    ///      deployment: a deal that selects BONDS then fails closed in `admit`. The binding is the
    ///      reputation's own address (its `packageId` pins it), so a user signing this reputation
    ///      knows the only vault whose locks can ever back its deals.
    address public immutable bondsVault;
    /// @dev The smallest deal this module admits, in lots of `250 * 10^decimals` of the deal's token (Anexo R,
    ///      2026-09-28: an official deal moves at least one lot). Zero admits any size. The kernel has no such
    ///      floor — the size of a deal is the parties' and Core settles any amount; this is the module's policy,
    ///      fixed at deployment and therefore inside what signing its `packageId` consents to.
    uint256 public immutable minPrincipalLots;

    mapping(bytes32 => bool) public registeredHn;
    /// @dev The pair tag of a deal, carried by the first admit and matched by the second (§E.3.14.7).
    ///      It survives the activation because the claim spends it: the counterparty a credit is asked
    ///      for has to be the one the deal was actually made with.
    mapping(bytes32 dealId => bytes32 pairTag) public pairTagOf;
    /// @dev The rate window the claim circuit is told about — one day, matching the public module.
    uint256 internal constant EPOCH = 1 days;
    mapping(bytes32 => Pending) public pending;
    mapping(bytes32 => bool) public claimed;

    /// @dev A pool's reputation (Anexo R, 2026-09-29): the pool's own, public, per token, moved by the same
    ///      deltas as an account's (§E.3.15.5) but kept in the clear — a pool is a business whose record its LPs
    ///      and its counterparties want to read. `isPool` marks the subjects that are pools. `poolStats` is the
    ///      RECORD (every completed deal) and the penalties; `poolCredit` is what buys tier.
    struct PoolStats {
        uint256 count;
        uint256 volume;
        uint256 penalty;
    }

    /// @dev The pool is a peer (Anexo R, 2026-10-05): it climbs the same ladder as a person, in the clear. Credit is
    ///      once per distinct Provider (`poolCredited`, keyed by the `cpTag` the operator's vouch proves) and at most
    ///      `MAX_CREDITS_PER_EPOCH` per epoch; the cap is concurrent (`poolInFlight`) and takes the bond column only
    ///      while every open deal of the pool carries its lock (`poolUnbondedInFlight == 0`).
    struct PoolCredit {
        uint256 count;
        uint256 volume;
    }

    struct Rate {
        uint64 epoch;
        uint64 credits;
    }

    uint64 internal constant MAX_CREDITS_PER_EPOCH = 16;

    mapping(bytes32 subject => mapping(address token => PoolStats)) public poolStats;
    mapping(bytes32 subject => bool) public isPool;
    mapping(bytes32 subject => mapping(address token => PoolCredit)) public poolCredit;
    mapping(bytes32 subject => mapping(address token => uint256)) public poolInFlight;
    mapping(bytes32 subject => mapping(address token => uint256)) public poolUnbondedInFlight;
    mapping(bytes32 subject => mapping(bytes32 cpTag => mapping(address token => bool))) public poolCredited;
    mapping(bytes32 subject => mapping(address token => Rate)) internal _poolRate;
    /// @dev Per pool deal: the Provider's tag the operator proved, and whether the pool's side carried its lock.
    mapping(bytes32 dealId => bytes32 cpTag) public poolCpTagOf;
    mapping(bytes32 dealId => bool) internal _poolDealBonded;
    /// @dev The pool deal a Provider's per-deal subject belongs to: the terminal names the counterparty, not the deal.
    mapping(bytes32 providerSubject => bytes32 dealId) internal _poolDealOf;
    bytes32 internal constant POOL_DEAL = keccak256("pluri:private-reputation:pool-deal");
    /// @dev The pair tag a human vouched with on a pool's side, held until the Provider's side arrives (transient).
    bytes32 internal constant VOUCH_PAIR = keccak256("pluri:private-reputation:vouch-pair");
    /// @dev The voucher's flag, held until the Provider's side arrives (transient, 2026-10-01).
    bytes32 internal constant VOUCH_VERIFIED = keccak256("pluri:private-reputation:vouch-verified");
    /// @dev Whether a deal may CREDIT (2026-10-01): both sides were verified accounts when it activated — or,
    ///      across from a pool, the pool's verified operator vouched for a verified Provider (Anexo R, 2026-09-29
    ///      and 2026-10-05: a human co-signs the pair rule on the pool's side, or a Provider could farm against a
    ///      friendly pool one fresh "counterparty" per deal). Written once by `admit`, never cleared: both sides'
    ///      claims and the pool's terminal read it. False is not a penalty — the deal still records.
    mapping(bytes32 dealId => bool) public creditable;

    event AccountRegistered(bytes32 indexed hn, bytes32 leaf0, uint256 index);
    /// @dev An account without a Passport (2026-10-01): no human named, a genesis that says so.
    event OpenAccountRegistered(bytes32 leaf0, uint256 index);
    /// @dev An open account verified in place by the human behind `hn` (2026-10-01).
    event AccountVerified(bytes32 indexed hn, bytes32 newLeaf, uint256 index);
    event Admitted(address indexed wallet, bytes32 indexed subject, address token, uint256 principal);
    /// @dev The side's recovery hints (Anexo R, 2026-09-29): the counterparty's `S` and the pair secret, each
    ///      under a pad only the account rebuilds. Keyed by deal and subject, which is how the account finds
    ///      its own from `sk_id` and the list of deals.
    event PoolTerminal(bytes32 indexed pool, IReputation.Close kind, address token, uint256 principal);
    event RecoveryHints(bytes32 indexed dealId, bytes32 indexed dealSubject, bytes32 hintS, bytes32 hintK);
    event TerminalPending(bytes32 indexed subject, IReputation.Close kind, address token, uint256 principal);
    event DeltaClaimed(bytes32 indexed dealSubject, bytes32 indexed dealId, bytes32 newLeaf);

    error ZeroAddress();
    error BadFee();
    error BadTreeDepth();
    error Unauthorized();
    error HumanityNotProven();
    error AlreadyRegistered();
    error AccountNotVerified();
    error UnknownRoot();
    error AdmitProofFailed();
    error ClaimProofFailed();
    error PairMismatch();
    error NoPair();
    error SideMismatch();
    error UnsupportedVault();
    error AlreadyPending();
    error AlreadyClaimed();
    error NothingToClaim();
    error BelowMinimum();
    error CapExceeded();
    /// @dev A bond is a verified account's (2026-10-01): an open side proved none, and cannot ask for one.
    error BondsNeedPassport();

    constructor(
        IPassport passport_,
        PoseidonTree accountTree_,
        IAccountVerifier accountVerifier_,
        IBundleVerifier bundleVerifier_,
        IClaimVerifier claimVerifier_,
        address feeRecipient_,
        uint256 activationBps_,
        uint256 completionBps_,
        uint256 contestBps_,
        uint256 contestFloor_,
        address operator_,
        address bondsVault_,
        uint256 minPrincipalLots_,
        address governor_
    ) Governed(governor_) {
        if (
            address(passport_) == address(0) || address(accountTree_) == address(0)
                || address(accountVerifier_) == address(0) || address(bundleVerifier_) == address(0)
                || address(claimVerifier_) == address(0) || feeRecipient_ == address(0) || operator_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (activationBps_ > 10_000 || completionBps_ > 10_000 || contestBps_ > 10_000) revert BadFee();
        if (contestFloor_ > type(uint128).max) revert BadFee();
        Fees memory initial =
            Fees(uint16(activationBps_), uint16(completionBps_), uint16(contestBps_), uint128(contestFloor_));
        // A governed module starts inside the bounds it can be moved in, or the bounds would promise nothing.
        if (governor_ != address(0)) _requireInBounds(initial);
        if (accountTree_.depth() != TREE_DEPTH) revert BadTreeDepth();
        passport = passport_;
        accountTree = accountTree_;
        accountVerifier = accountVerifier_;
        bundleVerifier = bundleVerifier_;
        claimVerifier = claimVerifier_;
        feeRecipient = feeRecipient_;
        _fees = initial;
        operator = operator_;
        bondsVault = bondsVault_;
        minPrincipalLots = minPrincipalLots_;
    }

    // ------------------------------------------------------------------ register (F1)

    /// @notice Registers the initial leaf of an account. Must run in the same tx as, and after,
    ///         `PrivatePassport.register` with the same `hn`: one human, one account.
    function register(bytes calldata proof, bytes32 hn, bytes32 leaf0) external {
        if (registeredHn[hn]) revert AlreadyRegistered();
        if (!IPrivatePassport(address(passport)).humanitySpent(hn)) revert HumanityNotProven();
        if (!accountVerifier.verifyAccount(proof, hn, leaf0)) revert AccountNotVerified();
        registeredHn[hn] = true;
        (uint256 index,) = accountTree.insert(leaf0);
        emit AccountRegistered(hn, leaf0, index);
    }

    /// @notice Registers an account WITHOUT a proof of humanity (2026-10-01): its genesis is every counter zero
    ///         and `verified = 0`, proven, so nobody enters the tree with a record they never earned. There is
    ///         no one-per-human rule to keep — an open account names no human — and none is needed: it buys no
    ///         tier, carries no bond, and its record says what it is.
    function registerOpen(bytes calldata proof, bytes32 leaf0) external {
        if (!accountVerifier.verifyOpenAccount(proof, leaf0)) revert AccountNotVerified();
        (uint256 index,) = accountTree.insert(leaf0);
        emit OpenAccountRegistered(leaf0, index);
    }

    /// @notice Verifies an open account in place (2026-10-01). Runs in the same bundle as, and after,
    ///         `PrivatePassport.register` with the same `hn` — exactly like `register`, and it spends the same
    ///         one-per-human slot: a human verifies ONE account, whether at registration or later. The leaf
    ///         keeps every stat; only its flag changes, so its deals with verified accounts credit from now on.
    function upgrade(bytes calldata proof, bytes32 hn, bytes32 repRoot, bytes32 nullRep, bytes32 newLeaf) external {
        if (registeredHn[hn]) revert AlreadyRegistered();
        if (!IPrivatePassport(address(passport)).humanitySpent(hn)) revert HumanityNotProven();
        if (!accountTree.isKnownRoot(repRoot)) revert UnknownRoot();
        if (!accountVerifier.verifyUpgrade(proof, hn, repRoot, nullRep, newLeaf)) revert AccountNotVerified();
        registeredHn[hn] = true;
        // The version nullifier: an upgrade is a transition like any other, so it serializes against an
        // activation or a claim of the same version.
        accountTree.spend(nullRep);
        (uint256 index,) = accountTree.insert(newLeaf);
        emit AccountVerified(hn, newLeaf, index);
    }

    // ------------------------------------------------------------------ activation edge (F2)

    /// @dev Transient slots of one activation, keyed by the deal: the first side's leaf and pair tag,
    ///      held until the second side arrives. Transient, so nothing of a half-admitted deal survives
    ///      the transaction — and there is no transaction in which only one side is admitted.
    bytes32 internal constant FIRST_LEAF = keccak256("pluri:private-reputation:first-leaf");
    bytes32 internal constant FIRST_PAIR = keccak256("pluri:private-reputation:first-pair");
    bytes32 internal constant FIRST_VERIFIED = keccak256("pluri:private-reputation:first-verified");

    /// @inheritdoc IReputation
    /// @dev `data` is `abi.encode(IBundleVerifier.BundleInputs, bytes proof)`: the side's `prepare_side`
    ///      inputs and proof, which the private passport verified a moment earlier in the same `engage`.
    ///      This module reads only the inputs and asks for the ticket. Kernel-only, so a proof can only
    ///      spend its nullifier inside an activation of the deal it names.
    function admit(address wallet, bytes32 dealId, address token, uint256 principal, address vault, bytes calldata data)
        external
        returns (bytes32 subject)
    {
        if (msg.sender != operator) revert Unauthorized();
        // The F3 binding (§E.3.15.6): a vault-less deal (vault == 0) or THE bound private vault —
        // nothing else. A counterparty signs a BONDS deal trusting that the lock exists; a foreign
        // vault under this same reputation would fake that protection.
        if (vault != address(0) && vault != bondsVault) revert UnsupportedVault();
        if (minPrincipalLots != 0 && principal < _lot(token) * minPrincipalLots) revert BelowMinimum();
        if (IPrivatePassport(address(passport)).poolSubjectOf(wallet) != bytes32(0)) {
            return _admitPool(wallet, dealId, token, principal, vault, data);
        }
        IBundleVerifier.BundleInputs memory inputs = abi.decode(data, (IBundleVerifier.BundleInputs));
        if (inputs.dealId != dealId || inputs.token != token || inputs.principal != principal) {
            revert SideMismatch();
        }
        // The bond column of the cap is proven when, and only when, the deal carries the lock: a
        // bonded proof in a vault-less deal would buy the higher cap with a lock nobody reserves.
        if ((vault == address(0)) != (inputs.lockCommit == bytes32(0))) revert SideMismatch();
        // The bond column is a verified account's (2026-10-01). The circuit already refuses to prove a bonded
        // open side; this is the module's own reading of the same flag.
        if (inputs.lockCommit != bytes32(0) && !inputs.verified) revert BondsNeedPassport();
        if (inputs.newLeaf == bytes32(0)) revert SideMismatch();
        if (!accountTree.isKnownRoot(inputs.repRoot)) revert UnknownRoot();
        if (!bundleVerifier.wasProven(inputs)) revert AdmitProofFailed();
        // Burn the version nullifier: two activations against the same account version serialize here.
        accountTree.spend(inputs.nullRep);
        subject = inputs.dealSubject;
        if (_poolDeal(dealId)) {
            // Across from a pool the Provider's leaf goes in alone, and its pair tag is kept for its claim. The pool's
            // side is its operator's vouch (2026-10-05), so the tags must match — the pair rule, as between two
            // people — and the deal credits if both the operator and the Provider are verified. Either way the
            // completed deal records. The Provider's subject points back at the deal for the pool's terminal.
            bytes32 vouchPair = _tload(keccak256(abi.encode(VOUCH_PAIR, dealId)));
            if (vouchPair != bytes32(0)) {
                if (vouchPair != inputs.pairTag) revert PairMismatch();
                if (inputs.verified && _tload(keccak256(abi.encode(VOUCH_VERIFIED, dealId))) != bytes32(0)) {
                    creditable[dealId] = true;
                }
            }
            pairTagOf[dealId] = inputs.pairTag;
            _poolDealOf[inputs.dealSubject] = dealId;
            accountTree.insert(inputs.newLeaf);
        } else {
            _admitSide(dealId, inputs.newLeaf, inputs.pairTag, inputs.verified);
        }
        emit RecoveryHints(dealId, subject, inputs.hintS, inputs.hintK);
        emit Admitted(wallet, subject, token, principal);
    }

    /// @dev The side of an official pool: no account proof, no leaf, no nullifier — the passport vouches the address
    ///      is a pool the pinned factory made, and the side is its operator's vouch (Anexo R, 2026-10-05). The pool is
    ///      a peer: its concurrent cap is checked here, in the clear, with the bond column when the deal carries the
    ///      pool's lock and every other open deal of it does too.
    function _admitPool(
        address wallet,
        bytes32 dealId,
        address token,
        uint256 principal,
        address vault,
        bytes calldata data
    ) internal returns (bytes32 subject) {
        subject = IPrivatePassport(address(passport)).poolSubjectOf(wallet);
        // The operator's vouch for the Provider, verified by the passport a moment ago.
        if (!VouchData.isVouch(data)) revert SideMismatch();
        (IBundleVerifier.VouchInputs memory v,) = VouchData.decode(data);
        if (v.dealId != dealId) revert SideMismatch();
        if (!bundleVerifier.wasVouched(v)) revert AdmitProofFailed();
        _tstore(keccak256(abi.encode(VOUCH_PAIR, dealId)), v.pairTag);
        if (v.verified) _tstore(keccak256(abi.encode(VOUCH_VERIFIED, dealId)), bytes32(uint256(1)));
        poolCpTagOf[dealId] = v.cpTag;

        bool bondedDeal = vault != address(0);
        uint256 next = poolInFlight[subject][token] + principal;
        bool withBond = bondedDeal && poolUnbondedInFlight[subject][token] == 0;
        if (next > poolCap(subject, token, withBond)) revert CapExceeded();
        poolInFlight[subject][token] = next;
        if (!bondedDeal) poolUnbondedInFlight[subject][token] += principal;
        _poolDealBonded[dealId] = bondedDeal;

        isPool[subject] = true;
        _tstore(keccak256(abi.encode(POOL_DEAL, dealId)), bytes32(uint256(1)));
        emit Admitted(wallet, subject, token, principal);
    }

    /// @notice A pool's score on the ladder of §E.3.14.7: its credit, less its penalties.
    function poolScore(bytes32 subject, address token) public view returns (uint256) {
        PoolCredit storage c = poolCredit[subject][token];
        return Tiers.score(c.count, c.volume, poolStats[subject][token].penalty, _lot(token));
    }

    /// @notice The concurrent cap a pool's score buys, in raw units of `token`.
    function poolCap(bytes32 subject, address token, bool withBond) public view returns (uint256) {
        return Tiers.cap(poolScore(subject, token), withBond, _lot(token) / 250);
    }

    function _tstore(bytes32 key, bytes32 value) internal {
        assembly ("memory-safe") {
            tstore(key, value)
        }
    }

    function _tload(bytes32 key) internal view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := tload(key)
        }
    }

    function _poolDeal(bytes32 dealId) internal view returns (bool yes) {
        bytes32 key = keccak256(abi.encode(POOL_DEAL, dealId));
        assembly ("memory-safe") {
            yes := tload(key)
        }
    }

    /// @dev One lot of `token`: 250 whole tokens, the unit the score buys tiers in (§E.3.14.7). Fail-closed: a token
    ///      that does not answer `decimals()`, or answers something no stablecoin would, has no lot.
    function _lot(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) revert BelowMinimum();
        uint256 decimals = abi.decode(ret, (uint256));
        if (decimals > 36) revert BelowMinimum();
        return 250 * 10 ** decimals;
    }

    /// @dev The first side of a deal parks its leaf, pair tag and flag; the second matches the pair (§E.3.14.7)
    ///      and inserts both leaves together — adjacent indices share every level above their common
    ///      subtree, so the tree is walked once. The pair tag persists: the claim spends it. So does the
    ///      deal's credit word (2026-10-01): it credits only when both sides are verified accounts.
    function _admitSide(bytes32 dealId, bytes32 leaf, bytes32 pairTag, bool verified) internal {
        bytes32 leafKey = keccak256(abi.encode(FIRST_LEAF, dealId));
        bytes32 pairKey = keccak256(abi.encode(FIRST_PAIR, dealId));
        bytes32 verifiedKey = keccak256(abi.encode(FIRST_VERIFIED, dealId));
        bytes32 first;
        bytes32 firstPair;
        bool firstVerified;
        assembly ("memory-safe") {
            first := tload(leafKey)
            firstPair := tload(pairKey)
            firstVerified := tload(verifiedKey)
        }
        if (first == bytes32(0)) {
            assembly ("memory-safe") {
                tstore(leafKey, leaf)
                tstore(pairKey, pairTag)
                tstore(verifiedKey, verified)
            }
            return;
        }
        if (firstPair != pairTag) revert PairMismatch();
        assembly ("memory-safe") {
            tstore(leafKey, 0)
            tstore(pairKey, 0)
            tstore(verifiedKey, 0)
        }
        pairTagOf[dealId] = pairTag;
        if (firstVerified && verified) creditable[dealId] = true;
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = first;
        leaves[1] = leaf;
        accountTree.insertMany(leaves);
    }

    // ------------------------------------------------------------------ terminal edge (F2)

    /// @inheritdoc IReputation
    /// @dev The counterparty is not read (2026-10-01): whether the deal may credit is `creditable[dealId]`,
    ///      decided at admission, not something the terminal re-derives from who was on the other side.
    function notifyTerminal(
        bytes32 subject,
        bytes32 counterparty,
        address token,
        uint256 principal,
        IReputation.Close kind
    ) external {
        if (msg.sender != operator) revert Unauthorized();
        if (isPool[subject]) {
            _poolTerminal(subject, counterparty, token, principal, kind);
            return;
        }
        // Whether this deal may credit is the deal's (`creditable`, decided at admission), not the kind's: a
        // Peaceful close stays Peaceful, and the claim applies it to the record always and to the credit only
        // when the deal is creditable — across from a pool, when a verified human vouched for the pair.
        if (claimed[subject]) revert AlreadyClaimed();
        if (pending[subject].token != address(0)) revert AlreadyPending();
        pending[subject] = Pending(kind, token, principal);
        emit TerminalPending(subject, kind, token, principal);
    }

    /// @dev A pool's terminal: the cap is released, the record and the penalties move as §E.3.15.5 says, and a
    ///      completed, creditable deal credits the pool once per distinct Provider and within the epoch's window.
    ///      A Provider who already credited the pool — or a deal over the window — burns nothing it could take back
    ///      later, exactly as between people.
    function _poolTerminal(
        bytes32 subject,
        bytes32 counterparty,
        address token,
        uint256 principal,
        IReputation.Close kind
    ) internal {
        bytes32 dealId = _poolDealOf[counterparty];
        poolInFlight[subject][token] -= principal;
        if (!_poolDealBonded[dealId]) poolUnbondedInFlight[subject][token] -= principal;
        _poolDelta(poolStats[subject][token], principal, kind);
        if (kind == IReputation.Close.Peaceful && creditable[dealId]) {
            if (_creditsPool(subject, poolCpTagOf[dealId], token)) {
                PoolCredit storage c = poolCredit[subject][token];
                c.count += 1;
                c.volume += principal;
            }
        }
        emit PoolTerminal(subject, kind, token, principal);
    }

    /// @dev True exactly once per (pool, Provider tag, token), and at most `MAX_CREDITS_PER_EPOCH` times per epoch. The
    ///      pair is burned either way: a credit refused by the window does not come back tomorrow.
    function _creditsPool(bytes32 subject, bytes32 cpTag, address token) internal returns (bool) {
        if (cpTag == bytes32(0) || poolCredited[subject][cpTag][token]) return false;
        poolCredited[subject][cpTag][token] = true;
        Rate storage r = _poolRate[subject][token];
        uint64 epoch = uint64(block.timestamp / EPOCH);
        if (r.epoch != epoch) {
            r.epoch = epoch;
            r.credits = 0;
        }
        if (r.credits >= MAX_CREDITS_PER_EPOCH) return false;
        r.credits += 1;
        return true;
    }

    /// @dev §E.3.15.5's table, in the clear.
    function _poolDelta(PoolStats storage st, uint256 principal, IReputation.Close kind) internal {
        if (kind == IReputation.Close.Peaceful) {
            st.count += 1;
            st.volume += principal;
        } else if (kind == IReputation.Close.Stalemate || kind == IReputation.Close.NoShow) {
            st.penalty += 5;
        } else if (kind == IReputation.Close.Deadlock) {
            st.penalty += 10;
        } else if (kind == IReputation.Close.ArbLoss) {
            st.penalty += 15;
        }
    }

    /// @notice Applies the terminal delta of one deal subject: verifies the claim proof against the
    ///         pending record, burns the version nullifier, inserts the delta leaf and marks the
    ///         subject claimed. The proof is the only authority — the caller is anyone.
    function claim(
        bytes32 dealId,
        bytes32 dealSubject,
        bytes32 newLeaf,
        bytes32 nullRep,
        bytes32 repRoot,
        bytes calldata proof
    ) external {
        if (claimed[dealSubject]) revert AlreadyClaimed();
        Pending memory p = pending[dealSubject];
        if (p.token == address(0)) revert NothingToClaim();
        if (!accountTree.isKnownRoot(repRoot)) revert UnknownRoot();
        // The two inputs the prover does not get to choose (§E.3.14.7): the pair tag both sides signed
        // up to when the deal activated, and the epoch, which the circuit cannot read for itself.
        bytes32 tag = pairTagOf[dealId];
        if (tag == bytes32(0)) revert NoPair();
        if (!claimVerifier.verifyClaim(
                dealId,
                dealSubject,
                newLeaf,
                nullRep,
                p.kind,
                p.token,
                p.principal,
                repRoot,
                tag,
                block.timestamp / EPOCH,
                creditable[dealId],
                proof
            )) {
            revert ClaimProofFailed();
        }
        accountTree.spend(nullRep);
        accountTree.insert(newLeaf);
        claimed[dealSubject] = true;
        delete pending[dealSubject];
        emit DeltaClaimed(dealSubject, dealId, newLeaf);
    }

    // ------------------------------------------------------------------ fee policy

    /// @inheritdoc IReputation
    /// @dev The fees in force: it moves when the DAO enacts new ones, and a deal signed under the old ones no longer
    ///      resolves.
    function packageId() public view returns (bytes32) {
        Fees memory f = _fees;
        return PackageId.reputation(
            address(this), feeRecipient, f.activationBps, f.completionBps, f.contestBps, f.contestFloor
        );
    }

    function activationBps() public view returns (uint256) {
        return _fees.activationBps;
    }

    function completionBps() public view returns (uint256) {
        return _fees.completionBps;
    }

    function contestBps() public view returns (uint256) {
        return _fees.contestBps;
    }

    function contestFloor() public view returns (uint256) {
        return _fees.contestFloor;
    }

    function fees() external view returns (Fees memory) {
        return _fees;
    }

    function pendingFees() external view returns (Fees memory f) {
        if (pendingAt != 0) f = abi.decode(_pendingPolicy, (Fees));
    }

    /// @notice The DAO proposes the fees of the deals activated once they are enacted, no earlier than `pendingAt`.
    function proposePolicy(Fees calldata f) external {
        _requireInBounds(f);
        _propose(abi.encode(f));
    }

    function _enact(bytes memory encoded) internal override {
        _fees = abi.decode(encoded, (Fees));
    }

    function _requireInBounds(Fees memory f) internal pure {
        if (
            f.activationBps > MAX_ACTIVATION_BPS || f.completionBps > MAX_COMPLETION_BPS
                || f.contestBps > MAX_CONTEST_BPS || f.contestFloor > MAX_CONTEST_FLOOR
        ) revert OutOfBounds();
    }

    /// @inheritdoc IReputation
    function invoiceActivation(uint256 principal) external view returns (uint256 amount, address recipient) {
        return (principal * activationBps() / 10_000, feeRecipient);
    }

    /// @inheritdoc IReputation
    function invoiceCompletion(uint256 principal) external view returns (uint256 amount, address recipient) {
        return (principal * completionBps() / 10_000, feeRecipient);
    }

    /// @inheritdoc IReputation
    function invoiceContest(uint256 principal) external view returns (uint256 amount, address recipient) {
        return (_contestDue(principal), feeRecipient);
    }

    /// @dev Same curve as the public reputation: 1% of `principal` when `contestBps == 100`, never
    ///      below `contestFloor`. Zero bps is a flat floor (free if the floor is also 0).
    function _contestDue(uint256 principal) internal view returns (uint256) {
        Fees memory f = _fees;
        if (f.contestBps == 0) return f.contestFloor;
        uint256 pct = principal * f.contestBps / 10_000;
        return pct < f.contestFloor ? f.contestFloor : pct;
    }
}
