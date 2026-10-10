// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {DealTerms, DealClocks, isTerminal} from "../libraries/Types.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {IEscrow} from "../interfaces/IEscrow.sol";
import {ICourt} from "./interfaces/ICourt.sol";
import {IHumanityVerifier} from "./interfaces/IHumanityVerifier.sol";
import {IBundleVerifier} from "./interfaces/IBundleVerifier.sol";
import {IBondVault} from "./interfaces/IBondVault.sol";
import {VouchData} from "./libraries/VouchData.sol";
import {Packages} from "../libraries/Packages.sol";
import {Governed} from "./Governed.sol";

/// @title ArbiterRegistry
/// @notice The tribunal the protocol pushes (PROTOCOLO.md Anexo R, 2026-09-28/29): one or three arbiters the parties chose
///         during the negotiation, out of one permissionless registry, bound to the deal before the principal is in
///         custody. It is an `ICourt` like any other: the kernel binds it at activation, the Controller opens it,
///         the kernel reads its ruling.
/// @dev Nobody curates this registry — not the DAO, not Labs: curating would be operating. Anyone bonds and becomes
///      choosable; what the parties see to choose by is the bond and the record (`statsOf`), because there is no
///      on-chain truth to grade an arbiter's judgement against.
///
///      A deal's life here:
///      * `bind` (kernel, inside `activate`): the court data names the panel and carries the Holder's, the
///        Provider's and each arbiter's EIP-712 signature over it. The panel must be one wallet or three distinct ones, none
///        of them a party; each commits `lockBps` of the principal from its free bond until the deal ends; the court's
///        windows must close strictly before the kernel's arbitration clock, so a ruling always exists before the
///        kernel's timeout could win the race; each must have published an encryption key, because the evidence
///        reaches an arbiter sealed to that key or not at all. The Holder's availability fee (`3 x availabilityBps`) is already
///        here, transferred by the kernel; a panel of one credits two thirds of it straight back. And the deal must
///        carry the bonds of `bondVault` (Anexo R, 2026-10-05): the panel is paid out of them, so a deal without them
///        has nothing to pay it with.
///      * `openCourt` (kernel): the fight starts, and it costs the opener nothing — there is no dispute fee. The
///        evidence never comes here: the parties' client seals the deal's conversation to each arbiter's
///        `encryptionKeyOf` and delivers it off-chain (PROTOCOLO.md §E.3.14.4).
///      * `commit` / `reveal`: one time to answer (Anexo R, 2026-09-29: four days, three to commit and one to
///        reveal), secret inside it. Each arbiter commits `keccak256(dealId, arbiter, vote, salt)`, and may change it
///        until the whole panel has committed; from then, or from the end of the commit window, it reveals. A vote is
///        1 (the Holder) or 2 (the Provider). Reveals open early only once every vote is fixed, so nobody reveals
///        into a vote that can still move.
///      * `readRuling`: nothing until the case is decided — every seat revealed, or the time to answer over, and
///        then whoever did not reveal abstained. Then the majority of revealed votes, and the Holder
///        on a tie or when nobody answered — a resolution always exists.
///      * `settle` (anyone, once the deal is terminal and the kernel disposed of its bonds): pays and releases.
///          - Bond share (what the vault left for this court, `bondShareBps` of the loser's lock, or half of it from
///            each side's lock when the parties settled while the court was open): among the arbiters who voted with
///            the ruling; among the whole panel if the parties settled (paid as if unanimous); to the winner if
///            nobody voted — the share was the loser's, and nobody earned it.
///          - Availability (per arbiter): earned when the deal ended without a dispute, or with one if the arbiter
///            voted (or the parties settled during the fight); otherwise back to the Holder.
///          - Abstention, once the court went to term: an abstainer forfeits `abstainSlashBps` of its lock while
///            someone else voted; the whole panel abstaining — a lone arbiter who never voted — forfeits all of it. A slash goes to the side the ruling went against: the one who lost
///            without being heard.
///      Everything is paid as a credit, withdrawn by its owner: a recipient the token refuses cannot block a
///      settlement. Solvency: the token balance is bonds + held fees + credits, and every path moves value between
///      those books without creating any.
///
///      The arbiter is not a party, twice (Anexo R, 2026-09-29): as a wallet, checked here against the terms;
///      and as a human, when the registry is deployed with a humanity verifier. Then each arbiter registers its
///      humanity nullifier with the same proof an account registers with, and each side of the deal must be a
///      private side whose `prepare_side` proof shows its own nullifier under this registry is none of the
///      panel's — the court reads both sides' proven inputs at `bind` and checks the registry, the panel and
///      the ticket. What it does not check: that an arbiter has no active deal with a party — not provable in
///      the private layer, and dropped.
///
///      The panel's `Policy` (the two windows, the exit delay, the lock, the abstention slash, the availability and
///      the bond share) is what the DAO may change (`Governed`, Anexo R 2026-10-06), and only for deals not yet
///      bound: a proposal must sit inside the fixed bounds below, waits `GOVERNANCE_DELAY` — longer than the
///      longest exit, so an arbiter who disagrees is out before it applies — and then anyone enacts it. The
///      `packageId` hashes the policy in force, so a deal signed under the old one does not activate. Each case keeps
///      the terms it was bound under, and the kernel keeps the prices it charged (`Deal.prices`): a change never
///      reaches a live deal. A zero `governor` freezes the policy for good.
// `openCourt` is payable only because `ICourt` is (the kernel forwards `msg.value`); this court rejects any value.
// slither-disable-next-line locked-ether
contract ArbiterRegistry is ICourt, EIP712, Governed {
    using SafeERC20 for IERC20;

    bytes32 public constant APPOINTMENT_TYPEHASH =
        keccak256("PanelAppointment(bytes32 dealId,address arbiter0,address arbiter1,address arbiter2,bytes32 policy)");

    /// @dev The bounds of a governed policy (Anexo R, 2026-10-06). A captured DAO can move the terms only inside them.
    uint64 public constant MIN_COMMIT_WINDOW = 1 days;
    uint64 public constant MAX_COMMIT_WINDOW = 7 days;
    uint64 public constant MIN_REVEAL_WINDOW = 12 hours;
    uint64 public constant MAX_REVEAL_WINDOW = 3 days;
    uint64 public constant MIN_EXIT_DELAY = 7 days;
    uint64 public constant MAX_EXIT_DELAY = 21 days;
    uint16 public constant MIN_LOCK_BPS = 500;
    uint16 public constant MAX_LOCK_BPS = 2_500;
    uint16 public constant MIN_ABSTAIN_SLASH_BPS = 2_500;
    uint16 public constant MAX_ABSTAIN_SLASH_BPS = 10_000;
    /// @dev Per arbiter: the Holder pays three, so 3% of the principal at most.
    uint16 public constant MIN_AVAILABILITY_BPS = 5;
    uint16 public constant MAX_AVAILABILITY_BPS = 100;
    uint16 public constant MIN_BOND_SHARE_BPS = 1_000;
    uint16 public constant MAX_BOND_SHARE_BPS = 5_000;
    uint8 internal constant HOLDER = 1;
    uint8 internal constant PROVIDER = 2;

    /// @dev The panel's terms and prices: what the DAO may change for deals not yet bound, and nothing else.
    ///      `availabilityBps` is per arbiter (the Holder pays three); `bondShareBps` is the panel's share of the
    ///      loser's bond lock (3000 = 30%, Anexo R 2026-10-05).
    struct Policy {
        uint64 commitWindow;
        uint64 revealWindow;
        uint64 exitDelay;
        uint16 lockBps;
        uint16 abstainSlashBps;
        uint16 availabilityBps;
        uint16 bondShareBps;
    }

    struct Arbiter {
        uint256 bond;
        uint256 locked;
        uint256 exitAmount;
        uint64 exitAt;
    }

    /// @dev The record a party chooses by. Counts, not grades.
    struct Stats {
        uint32 assigned;
        uint32 disputes;
        uint32 votes;
        uint32 abstentions;
        uint32 withRuling;
    }

    struct Case {
        address[3] arbiters; // seats past `size` are empty
        uint8 size; // 1 or 3
        address holder;
        address provider;
        address controller;
        uint256 principal;
        uint256 lock;
        uint256 availability; // the Holder's fee for the seats taken; the empty seats' went back at `bind`
        uint64 openedAt;
        // The terms this case was bound under: a later policy never reaches it.
        uint64 commitWindow;
        uint64 revealWindow;
        uint16 abstainSlashBps;
        bool settled;
        bytes32[3] commits;
        uint8[3] votes;
    }

    IEscrow public immutable kernel;
    IERC20 public immutable token;
    /// @dev No dispute fee (Anexo R, 2026-10-05): opening the court costs nothing, the loser's bond pays the panel.
    uint256 public constant contestFee = 0;
    /// @dev The vault whose bonds every deal of this panel carries, and where its share waits.
    address public immutable bondVault;
    /// @dev The humanity rule, all three or none: zero `humanityVerifier` is a registry that checks wallets only.
    IHumanityVerifier public immutable humanityVerifier;
    /// @dev The factory whose pools the humanity rule lets a human vouch for (Anexo R, 2026-09-29), pinned like the
    ///      private passport pins it. Zero: no Holder is a pool, and every side proves its own humanity.
    address public immutable poolFactory;
    IBundleVerifier public immutable bundleVerifier;
    bytes32 public immutable registryId;

    Policy internal _policy;

    mapping(address => Arbiter) public arbiterOf;
    mapping(address => Stats) internal _stats;
    mapping(bytes32 dealId => Case) internal _cases;
    mapping(address => uint256) public creditOf;
    mapping(address arbiter => bytes32 hn) public hnOf;
    mapping(bytes32 hn => address arbiter) public arbiterOfHn;
    /// @dev The X25519 public key the parties seal the evidence to. Not part of the policy: an arbiter rotates it
    ///      whenever it likes, and a party seals to the key current when it shares.
    mapping(address arbiter => bytes32 key) public encryptionKeyOf;

    event Deposited(address indexed arbiter, uint256 amount);
    event ExitRequested(address indexed arbiter, uint256 amount, uint64 at);
    event Exited(address indexed arbiter, uint256 amount);
    event Bound(bytes32 indexed dealId, address arbiter0, address arbiter1, address arbiter2, uint256 lock);
    event Opened(bytes32 indexed dealId);
    event Committed(bytes32 indexed dealId, address indexed arbiter);
    event Revealed(bytes32 indexed dealId, address indexed arbiter, uint8 vote);
    event Settled(bytes32 indexed dealId, uint8 ruling);
    event Slashed(bytes32 indexed dealId, address indexed arbiter, address indexed to, uint256 amount);
    event CreditWithdrawn(address indexed beneficiary, uint256 amount);
    event EncryptionKeySet(address indexed arbiter, bytes32 key);

    error ZeroAddress();
    error BadPolicy();
    error Unauthorized();
    error WrongToken();
    error PanelNotDistinct();
    error PartyOnPanel();
    error WindowsTooLong();
    error BadSignature();
    error NoCapacity();
    error UnknownCase();
    error AlreadyOpen();
    error NotOnPanel();
    error WindowClosed();
    error BadCommit();
    error BadReveal();
    error DealStillLive();
    error AlreadySettled();
    error TooEarly();
    error NothingToExit();
    error NoHumanityRule();
    error HumanTaken();
    error ArbiterNotHuman();
    error HumanityUnproven();
    error RegistryMismatch();
    error PanelMismatch();
    error BadPanelSize();
    error NoEncryptionKey();
    error BondsRequired();
    error BondsPending();

    constructor(
        address kernel_,
        address token_,
        Policy memory policy_,
        address governor_,
        address bondVault_,
        address humanityVerifier_,
        address bundleVerifier_,
        bytes32 registryId_,
        address poolFactory_
    ) EIP712("PluriSwap Panel", "1") Governed(governor_) {
        if (kernel_ == address(0) || token_ == address(0) || bondVault_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            uint256(policy_.availabilityBps) * 3 > 10_000 || policy_.bondShareBps > 10_000 || policy_.lockBps > 10_000
                || policy_.abstainSlashBps > 10_000 || policy_.commitWindow == 0 || policy_.revealWindow == 0
        ) revert BadPolicy();
        // A governed panel starts inside the bounds it can be moved in, or the bounds would promise nothing.
        if (governor_ != address(0)) _requireInBounds(policy_);
        kernel = IEscrow(kernel_);
        token = IERC20(token_);
        bondVault = bondVault_;
        _policy = policy_;
        if ((humanityVerifier_ == address(0)) != (bundleVerifier_ == address(0))) revert BadPolicy();
        humanityVerifier = IHumanityVerifier(humanityVerifier_);
        bundleVerifier = IBundleVerifier(bundleVerifier_);
        registryId = registryId_;
        poolFactory = poolFactory_;
    }

    // --- ICourt: policy ---------------------------------------------------------------------------------

    /// @inheritdoc ICourt
    /// @dev The whole policy that is not already a word of its own in the id: the bond token, the vault, the humanity
    ///      rule, the governor and the terms in force. A different one is a different package.
    function packageBinding() external view returns (address partner, uint256 key) {
        return _binding();
    }

    /// @inheritdoc ICourt
    /// @dev Whatever the court is paid is the arbiters', so it comes here.
    function feeRecipient() external view returns (address) {
        return address(this);
    }

    /// @inheritdoc ICourt
    function activationBps() external view returns (uint256) {
        return 3 * uint256(_policy.availabilityBps);
    }

    /// @inheritdoc ICourt
    function bondShareBps() external view returns (uint256) {
        return _policy.bondShareBps;
    }

    function availabilityBps() external view returns (uint256) {
        return _policy.availabilityBps;
    }

    /// @inheritdoc ICourt
    /// @dev The policy in force: it moves when the DAO enacts a new one, and a deal signed under the old one no
    ///      longer resolves.
    function packageId() public view returns (bytes32) {
        (address partner, uint256 key) = _binding();
        return PackageId.arbitration(
            address(this),
            partner,
            key,
            contestFee,
            address(this),
            3 * uint256(_policy.availabilityBps),
            _policy.bondShareBps
        );
    }

    /// @inheritdoc ICourt
    /// @dev A bound panel can always be escalated to: its arbiters accepted it and their bond is committed.
    function available(bytes32 dealId) external view returns (bool) {
        return _cases[dealId].principal != 0;
    }

    /// @dev The digest the Holder, the Provider and each arbiter sign for `panel` on `dealId`, under the terms in force.
    function appointmentDigest(bytes32 dealId, address[3] memory panel) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(APPOINTMENT_TYPEHASH, dealId, panel[0], panel[1], panel[2], policyHash()))
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // --- the policy -------------------------------------------------------------------------------------

    function policy() external view returns (Policy memory) {
        return _policy;
    }

    function pendingPolicy() external view returns (Policy memory p) {
        if (pendingAt != 0) p = abi.decode(_pendingPolicy, (Policy));
    }

    /// @dev What the appointment signs: the terms a deal bound now would get.
    function policyHash() public view returns (bytes32) {
        return keccak256(abi.encode(_policy));
    }

    function commitWindow() external view returns (uint64) {
        return _policy.commitWindow;
    }

    function revealWindow() external view returns (uint64) {
        return _policy.revealWindow;
    }

    function exitDelay() external view returns (uint64) {
        return _policy.exitDelay;
    }

    function lockBps() external view returns (uint256) {
        return _policy.lockBps;
    }

    function abstainSlashBps() external view returns (uint256) {
        return _policy.abstainSlashBps;
    }

    /// @notice The DAO proposes new terms and prices for the deals bound once they are enacted, no earlier than
    ///         `pendingAt`.
    function proposePolicy(Policy calldata p) external {
        _requireInBounds(p);
        _propose(abi.encode(p));
    }

    function _enact(bytes memory encoded) internal override {
        _policy = abi.decode(encoded, (Policy));
    }

    function statsOf(address arbiter) external view returns (Stats memory) {
        return _stats[arbiter];
    }

    function caseOf(bytes32 dealId)
        external
        view
        returns (address[3] memory arbiters, uint256 principal, uint256 lock, uint64 openedAt)
    {
        Case storage c = _cases[dealId];
        return (c.arbiters, c.principal, c.lock, c.openedAt);
    }

    // --- the bond ---------------------------------------------------------------------------------------

    function deposit(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        arbiterOf[msg.sender].bond += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Starts taking `amount` of free bond out. It stops backing new deals now and leaves after
    ///         `exitDelay`, so an arbiter cannot empty its bond between being chosen and being slashed.
    function requestExit(uint256 amount) external {
        Arbiter storage a = arbiterOf[msg.sender];
        if (amount == 0 || amount > _free(a)) revert NoCapacity();
        a.exitAmount += amount;
        a.exitAt = uint64(block.timestamp) + _policy.exitDelay;
        emit ExitRequested(msg.sender, amount, a.exitAt);
    }

    function exit() external {
        Arbiter storage a = arbiterOf[msg.sender];
        uint256 amount = a.exitAmount;
        if (amount == 0) revert NothingToExit();
        if (block.timestamp < a.exitAt) revert TooEarly();
        a.exitAmount = 0;
        a.bond -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Exited(msg.sender, amount);
    }

    /// @notice Registers the human behind an arbiter wallet: the humanity nullifier, proven the way an account
    ///         proves it. One human, one arbiter seat.
    function registerHumanity(bytes calldata proof, bytes32 hn) external {
        if (address(humanityVerifier) == address(0)) revert NoHumanityRule();
        if (arbiterOfHn[hn] != address(0) || hnOf[msg.sender] != bytes32(0)) revert HumanTaken();
        if (!humanityVerifier.verifyHumanity(proof, hn)) revert ArbiterNotHuman();
        hnOf[msg.sender] = hn;
        arbiterOfHn[hn] = msg.sender;
    }

    /// @notice Publishes the key the parties seal a case's evidence to. Zero is no key: an arbiter without one
    ///         cannot be bound to a deal, because nobody could show it anything.
    function setEncryptionKey(bytes32 key) external {
        if (key == bytes32(0)) revert NoEncryptionKey();
        encryptionKeyOf[msg.sender] = key;
        emit EncryptionKeySet(msg.sender, key);
    }

    function withdrawCredit() external {
        uint256 amount = creditOf[msg.sender];
        creditOf[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit CreditWithdrawn(msg.sender, amount);
    }

    // --- ICourt: the deal -------------------------------------------------------------------------------

    /// @inheritdoc ICourt
    /// @dev `data = abi.encode(address[3] panel, bytes holderSig, bytes providerSig, bytes[3] arbiterSigs)`, every
    ///      signature over `PanelAppointment(dealId, panel, policyHash())` in this registry's domain: everyone signs
    ///      the terms in force, and a policy enacted in between voids them (the id they named stops resolving too). A panel is one arbiter or three
    ///      (Anexo R, 2026-09-29), filling the seats in order: `[a, 0, 0]` or `[a, b, c]`. Never two: the Holder's
    ///      default on a tie would give an even panel a side. The kernel pulled the availability of three, the
    ///      share the signed id names; a panel of one credits the two empty seats' back to the Holder right here, so
    ///      neither the kernel nor a pool reserving that share has to learn the size.
    function bind(
        bytes32 dealId,
        DealTerms calldata t,
        uint256 activationFee,
        bytes calldata data,
        bytes calldata holderData,
        bytes calldata providerData
    ) external {
        if (msg.sender != address(kernel)) revert Unauthorized();
        if (t.token != address(token)) revert WrongToken();
        Policy memory p = _policy;
        if (uint256(p.commitWindow) + p.revealWindow >= t.arbitrationDuration) revert WindowsTooLong();
        if (!_carriesBonds(t.packageIds)) revert BondsRequired();
        (address[3] memory panel, bytes memory holderSig, bytes memory providerSig, bytes[3] memory accepts) =
            abi.decode(data, (address[3], bytes, bytes, bytes[3]));
        uint8 size = _sizeOf(panel);
        for (uint256 i; i < size; i++) {
            if (panel[i] == address(0)) revert ZeroAddress();
            if (panel[i] == t.holder || panel[i] == t.provider || panel[i] == t.controller) revert PartyOnPanel();
            if (encryptionKeyOf[panel[i]] == bytes32(0)) revert NoEncryptionKey();
            for (uint256 k = i + 1; k < size; k++) {
                if (panel[i] == panel[k]) revert PanelNotDistinct();
            }
        }
        bytes32 digest = appointmentDigest(dealId, panel);
        if (!SignatureChecker.isValidSignatureNow(t.holder, digest, holderSig)) revert BadSignature();
        if (!SignatureChecker.isValidSignatureNow(t.provider, digest, providerSig)) revert BadSignature();
        if (address(humanityVerifier) != address(0)) {
            bytes32[3] memory panelHns; // an empty seat is the zero hn, which no human's nullifier is
            for (uint256 i; i < size; i++) {
                panelHns[i] = hnOf[panel[i]];
                if (panelHns[i] == bytes32(0)) revert ArbiterNotHuman();
            }
            // A pool has no human of its own: its side is a human's vouch, and that human is the one who must not be
            // on the panel (Anexo R, 2026-09-29). Only an official pool's side may be a vouch — anyone else proves
            // their own humanity, or a party on the panel could hide behind somebody else's.
            if (_isPool(t.holder)) _requireVouchNotOnPanel(dealId, holderData, panelHns);
            else _requireNotOnPanel(dealId, holderData, panelHns);
            _requireNotOnPanel(dealId, providerData, panelHns);
        }
        uint256 lock = t.principal * p.lockBps / 10_000;
        for (uint256 i; i < size; i++) {
            if (!SignatureChecker.isValidSignatureNow(panel[i], digest, accepts[i])) revert BadSignature();
            Arbiter storage a = arbiterOf[panel[i]];
            if (_free(a) < lock) revert NoCapacity();
            a.locked += lock;
            _stats[panel[i]].assigned++;
        }
        Case storage c = _cases[dealId];
        c.arbiters = panel;
        c.size = size;
        c.holder = t.holder;
        c.provider = t.provider;
        c.controller = t.controller;
        c.principal = t.principal;
        c.lock = lock;
        c.commitWindow = p.commitWindow;
        c.revealWindow = p.revealWindow;
        c.abstainSlashBps = p.abstainSlashBps;
        uint256 kept = activationFee * size / 3;
        c.availability = kept;
        if (activationFee != kept) creditOf[t.holder] += activationFee - kept;
        emit Bound(dealId, panel[0], panel[1], panel[2], lock);
    }

    /// @inheritdoc ICourt
    function openCourt(bytes32 dealId, address) external payable {
        if (msg.sender != address(kernel)) revert Unauthorized();
        if (msg.value != 0) revert BadPolicy();
        Case storage c = _cases[dealId];
        if (c.principal == 0) revert UnknownCase();
        if (c.openedAt != 0) revert AlreadyOpen();
        c.openedAt = uint64(block.timestamp);
        for (uint256 i; i < c.size; i++) {
            _stats[c.arbiters[i]].disputes++;
        }
        emit Opened(dealId);
    }

    function commit(bytes32 dealId, bytes32 hash) external {
        Case storage c = _cases[dealId];
        uint256 i = _seat(c, msg.sender);
        if (c.openedAt == 0 || block.timestamp >= c.openedAt + c.commitWindow || _allCommitted(c)) {
            revert WindowClosed();
        }
        if (hash == bytes32(0)) revert BadCommit();
        c.commits[i] = hash;
        emit Committed(dealId, msg.sender);
    }

    function reveal(bytes32 dealId, uint8 vote, bytes32 salt) external {
        Case storage c = _cases[dealId];
        uint256 i = _seat(c, msg.sender);
        if (c.openedAt == 0 || block.timestamp >= _answerBy(c)) revert WindowClosed();
        if (block.timestamp < uint256(c.openedAt) + c.commitWindow && !_allCommitted(c)) revert WindowClosed();
        if (vote != HOLDER && vote != PROVIDER) revert BadReveal();
        if (c.votes[i] != 0 || keccak256(abi.encode(dealId, msg.sender, vote, salt)) != c.commits[i]) {
            revert BadReveal();
        }
        c.votes[i] = vote;
        emit Revealed(dealId, msg.sender, vote);
    }

    /// @inheritdoc ICourt
    function readRuling(bytes32 dealId) public view returns (uint8) {
        Case storage c = _cases[dealId];
        if (c.openedAt == 0 || !_atTerm(c)) return 0;
        return _ruling(c);
    }

    // --- settlement -------------------------------------------------------------------------------------

    /// @notice Pays and releases a bound deal once it is terminal and its bonds are disposed of. Anyone: the arbiters
    ///         are the ones who want it.
    function settle(bytes32 dealId) external {
        Case storage c = _cases[dealId];
        if (c.principal == 0) revert UnknownCase();
        if (c.settled) revert AlreadySettled();
        if (!isTerminal(kernel.status(dealId))) revert DealStillLive();
        // The share reaches the vault when the kernel disposes of the bonds, which it may still owe: settling
        // before that would pay the arbiters nothing, for good.
        if (kernel.postPending(dealId) & (Packages.POST_BOND_A | Packages.POST_BOND_B) != 0) revert BondsPending();
        c.settled = true;

        DealClocks memory clocks = kernel.clocks(dealId);
        bool opened = c.openedAt != 0;
        bool disputed = opened || clocks.disputedAt != 0;
        bool atTerm = opened && _atTerm(c);
        uint8 ruling = atTerm ? _ruling(c) : 0;

        _payAvailability(c, disputed, opened, atTerm);
        _payShare(c, _collectShare(dealId), atTerm, ruling);
        if (atTerm) _judgeAbstentions(dealId, c, ruling);
        for (uint256 i; i < c.size; i++) {
            arbiterOf[c.arbiters[i]].locked -= c.lock;
        }
        emit Settled(dealId, ruling);
    }

    function _payAvailability(Case storage c, bool disputed, bool opened, bool atTerm) internal {
        uint256 n = c.size;
        uint256 each = c.availability / n;
        uint256 refund = c.availability - n * each;
        for (uint256 i; i < n; i++) {
            // Earned by standing by when nothing was disputed; by taking part when something was. Settling during
            // the fight counts as taking part: the arbiters were there and the parties used them to agree.
            bool earned = !disputed || (opened && (!atTerm || c.votes[i] != 0));
            if (earned) creditOf[c.arbiters[i]] += each;
            else refund += each;
        }
        if (refund != 0) creditOf[c.holder] += refund;
    }

    /// @dev What the vault left for this court on this deal, brought here. Only a court that was opened has one: a
    ///      ruling or an agreement in court is the only way the kernel leaves a share.
    function _collectShare(bytes32 dealId) internal returns (uint256) {
        (address to,, uint256 amount) = IBondVault(bondVault).shareOf(dealId);
        if (to != address(this) || amount == 0) return 0;
        return IBondVault(bondVault).collect(dealId);
    }

    /// @dev The share among the arbiters who voted with the ruling, or the whole panel when the parties settled
    ///      during the fight; to the winner when nobody answered, since nobody earned it.
    function _payShare(Case storage c, uint256 amount, bool atTerm, uint8 ruling) internal {
        if (amount == 0) return;
        address[3] memory winners;
        uint256 n;
        for (uint256 i; i < c.size; i++) {
            if (!atTerm || c.votes[i] == ruling) winners[n++] = c.arbiters[i];
        }
        if (n == 0) {
            creditOf[ruling == PROVIDER ? c.provider : c.holder] += amount;
            return;
        }
        uint256 each = amount / n;
        for (uint256 i; i < n; i++) {
            creditOf[winners[i]] += each;
        }
        uint256 dust = amount - each * n;
        if (dust != 0) creditOf[winners[0]] += dust;
    }

    function _judgeAbstentions(bytes32 dealId, Case storage c, uint8 ruling) internal {
        uint256 abstained;
        for (uint256 i; i < c.size; i++) {
            if (c.votes[i] == 0) abstained++;
        }
        address loser = ruling == HOLDER ? c.provider : c.holder;
        uint256 slash = abstained == c.size ? c.lock : c.lock * c.abstainSlashBps / 10_000;
        for (uint256 i; i < c.size; i++) {
            address a = c.arbiters[i];
            Stats storage st = _stats[a];
            if (c.votes[i] == 0) {
                st.abstentions++;
                if (slash != 0) {
                    arbiterOf[a].bond -= slash;
                    creditOf[loser] += slash;
                    emit Slashed(dealId, a, loser, slash);
                }
            } else {
                st.votes++;
                if (c.votes[i] == ruling) st.withRuling++;
            }
        }
    }

    // --- internals --------------------------------------------------------------------------------------

    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev One side proved, in this transaction, that its human is none of the panel's, under this registry.
    function _requireNotOnPanel(bytes32 dealId, bytes calldata side, bytes32[3] memory panelHns) internal view {
        if (side.length == 0 || VouchData.isVouch(side)) revert HumanityUnproven();
        IBundleVerifier.BundleInputs memory i = abi.decode(side, (IBundleVerifier.BundleInputs));
        if (i.dealId != dealId) revert HumanityUnproven();
        if (uint256(i.registryId) % BN254_P != uint256(registryId) % BN254_P) revert RegistryMismatch();
        for (uint256 k; k < 3; k++) {
            if (i.arbiters[k] != panelHns[k]) revert PanelMismatch();
        }
        if (!bundleVerifier.wasProven(i)) revert HumanityUnproven();
    }

    /// @dev The human who vouched on a pool's side proved, in this transaction, that they are none of the panel.
    function _requireVouchNotOnPanel(bytes32 dealId, bytes calldata side, bytes32[3] memory panelHns) internal view {
        if (!VouchData.isVouch(side)) revert HumanityUnproven();
        (IBundleVerifier.VouchInputs memory v,) = VouchData.decode(side);
        if (v.dealId != dealId) revert HumanityUnproven();
        if (uint256(v.registryId) % BN254_P != uint256(registryId) % BN254_P) revert RegistryMismatch();
        for (uint256 k; k < 3; k++) {
            if (v.arbiters[k] != panelHns[k]) revert PanelMismatch();
        }
        if (!bundleVerifier.wasVouched(v)) revert HumanityUnproven();
    }

    /// @dev An official pool of the pinned factory. Fail-closed read: no factory, no code, or any odd answer is not
    ///      a pool, and that side proves its own humanity.
    function _isPool(address holder) internal view returns (bool) {
        if (poolFactory == address(0)) return false;
        (bool ok, bytes memory ret) = poolFactory.staticcall(abi.encodeWithSignature("isOfficial(address)", holder));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @dev Whether the signed ids name this panel's vault: the deal carries the bonds the panel is paid out of.
    function _carriesBonds(bytes32[] calldata ids) internal view returns (bool) {
        bytes32 id = IBondVault(bondVault).packageId();
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    /// @dev The policy in force and who may move it. The kernel reads it only to resolve a deal at activation, and
    ///      charges every live deal the prices it copied then, so a new policy never drifts an open case.
    function _binding() internal view returns (address, uint256) {
        return (
            address(this),
            uint256(
                keccak256(
                    abi.encode(
                        address(token),
                        policyHash(),
                        governor,
                        bondVault,
                        address(humanityVerifier),
                        address(bundleVerifier),
                        registryId,
                        poolFactory
                    )
                )
            )
        );
    }

    function _requireInBounds(Policy memory p) internal pure {
        if (
            p.commitWindow < MIN_COMMIT_WINDOW || p.commitWindow > MAX_COMMIT_WINDOW
                || p.revealWindow < MIN_REVEAL_WINDOW || p.revealWindow > MAX_REVEAL_WINDOW
                || p.exitDelay < MIN_EXIT_DELAY || p.exitDelay > MAX_EXIT_DELAY || p.lockBps < MIN_LOCK_BPS
                || p.lockBps > MAX_LOCK_BPS || p.abstainSlashBps < MIN_ABSTAIN_SLASH_BPS
                || p.abstainSlashBps > MAX_ABSTAIN_SLASH_BPS || p.availabilityBps < MIN_AVAILABILITY_BPS
                || p.availabilityBps > MAX_AVAILABILITY_BPS || p.bondShareBps < MIN_BOND_SHARE_BPS
                || p.bondShareBps > MAX_BOND_SHARE_BPS
        ) revert OutOfBounds();
    }

    /// @dev One arbiter in the first seat, or three: anything else is not a panel.
    function _sizeOf(address[3] memory panel) internal pure returns (uint8) {
        if (panel[0] == address(0)) revert BadPanelSize();
        if (panel[1] == address(0) && panel[2] == address(0)) return 1;
        if (panel[1] == address(0) || panel[2] == address(0)) revert BadPanelSize();
        return 3;
    }

    /// @dev Bond that can back a new deal: not committed to a live one and not on its way out.
    function _free(Arbiter storage a) internal view returns (uint256) {
        uint256 unavailable = a.locked + a.exitAmount;
        return a.bond > unavailable ? a.bond - unavailable : 0;
    }

    function _seat(Case storage c, address who) internal view returns (uint256) {
        for (uint256 i; i < c.size; i++) {
            if (c.arbiters[i] == who) return i;
        }
        revert NotOnPanel();
    }

    /// @dev The case is decided: every seat revealed, or the time to answer ran out.
    function _atTerm(Case storage c) internal view returns (bool) {
        return block.timestamp >= _answerBy(c) || _allRevealed(c);
    }

    function _answerBy(Case storage c) internal view returns (uint256) {
        return uint256(c.openedAt) + c.commitWindow + c.revealWindow;
    }

    function _allCommitted(Case storage c) internal view returns (bool) {
        for (uint256 i; i < c.size; i++) {
            if (c.commits[i] == bytes32(0)) return false;
        }
        return true;
    }

    function _allRevealed(Case storage c) internal view returns (bool) {
        for (uint256 i; i < c.size; i++) {
            if (c.votes[i] == 0) return false;
        }
        return true;
    }

    /// @dev The majority of revealed votes; the Holder on a tie and when nobody answered.
    function _ruling(Case storage c) internal view returns (uint8) {
        uint256 h;
        uint256 p;
        for (uint256 i; i < 3; i++) {
            if (c.votes[i] == HOLDER) h++;
            else if (c.votes[i] == PROVIDER) p++;
        }
        return p > h ? PROVIDER : HOLDER;
    }
}
