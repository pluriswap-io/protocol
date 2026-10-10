// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    Status,
    Deal,
    DealTerms,
    DealClocks,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit,
    PackageMods,
    PackageData,
    PackagePrices,
    BondAction,
    isTerminal
} from "./libraries/Types.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {Terms} from "./libraries/Terms.sol";
import {Consent} from "./libraries/Consent.sol";
import {Settlement} from "./libraries/Settlement.sol";
import {Clocks} from "./libraries/Clocks.sol";
import {Packages} from "./libraries/Packages.sol";
import {IReputation} from "./packages/interfaces/IReputation.sol";
import {IPaymentProof} from "./packages/interfaces/IPaymentProof.sol";
import {ICourt} from "./packages/interfaces/ICourt.sol";

contract Escrow is EIP712, ReentrancyGuardTransient, IEscrow {
    using SafeERC20 for IERC20;

    error TermsMismatch();
    error DeadlinePassed();
    error InvalidHolderSignature();
    error InvalidProviderSignature();
    error InvalidControllerSignature();
    error ControllerAcceptanceRequired();
    error NonceUsed();
    error DealExists();
    error Unauthorized();
    error WrongStatus();
    error DealIdMismatch();
    error DeadlineMismatch();
    error BpsMismatch();
    error PackageNotSelected();
    error EdgeOff();
    error NotRuled();
    error NothingPending();
    error SplitAfterDispute();
    error BadKernelFee();

    /// @dev Every per-deal event carries `dealId` as its first indexed topic, so one deal's history is a
    ///      filter on a node, not a download of the whole escrow.
    event Activated(
        bytes32 indexed dealId, address holder, address provider, address controller, address token, uint256 principal
    );
    event Transitioned(bytes32 indexed dealId, Status from, Status to);
    event Settled(bytes32 indexed dealId, Status status, uint256 holderAmt, uint256 providerAmt);
    event NonceCancelled(address signer, uint256 nonce);
    /// @dev The post-terminal debt of a deal, every time it changes: non-zero when `_close` could not
    ///      deliver a package call, and again after every `retryPostTerminal`, including the zero that
    ///      says a keeper can stop. Silence means nothing was ever owed. This is the only announcement
    ///      of a debt that `postPending` would otherwise only reveal to someone already looking, and the
    ///      reputation bits are deliberately never abandoned (EXT-12), so a module that never comes back
    ///      leaves them set forever -- that is a subject's capacity leaking, and it should be visible.
    event PostTerminalPending(bytes32 indexed dealId, uint8 pending);
    /// @dev A deadlock in a deal with no tribunal (Anexo R, 2026-09-24): the principal left custody to
    ///      `BURN` and reached neither party. `Settled` reports 0/0 for it; this is where the rest went.
    event PrincipalBurned(bytes32 indexed dealId, uint256 amount);
    /// @dev What the kernel had accrued in `token` for `feeRecipient`, delivered in one transfer.
    event FeesSwept(address indexed token, address indexed recipient, uint256 amount);

    uint16 internal constant ALL = 10_000;
    uint16 internal constant HALF = 5_000;
    /// @dev Where a deadlocked principal goes: an address nobody controls. Never the DAO, never a package,
    ///      never anyone who could profit from a deadlock happening.
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    /// @dev The ceiling on each kernel share, checked once at deployment: a typo in a constructor argument
    ///      must not become a kernel that takes a tenth of every deal for as long as it lives.
    uint16 public constant MAX_KERNEL_BPS = 100;

    /// @dev The kernel's own fee (Anexo R, 2026-10-02): every deal pays `activationBps` of its principal at
    ///      activation, from the Holder on top of the principal, and `completionBps` of it out of the pot at a
    ///      terminal that pays the Provider something and is not a stalemate. Both go to `feeRecipient`, the
    ///      DAO's receiving contract. All three are immutable: there is no setter, no switch and no vote over
    ///      the escrow; a different fee is a different deployment. The kernel stays without an owner — whoever
    ///      governs the recipient governs what it receives, never a deal.
    ///      Signed: the EIP-712 domain names this contract as `verifyingContract`, so every signature a deal
    ///      needs is a signature over this exact fee. A signature for another kernel does not activate here.
    address public immutable feeRecipient;
    uint16 public immutable activationBps;
    uint16 public immutable completionBps;

    /// @dev How a terminal splits the pot and what it tells the packages.
    struct Outcome {
        Status next;
        uint16 providerBps;
        IReputation.Close closeH;
        IReputation.Close closeP;
        BondAction bond;
    }

    mapping(address signer => mapping(uint256 nonce => bool consumed)) public used;
    mapping(address signer => mapping(uint256 nonce => bytes32 dealId)) public dealOf;
    mapping(bytes32 dealId => Deal) internal deals;
    Settlement.Store internal settlement;
    /// @dev Kernel fees charged and not yet swept, per token. Accrued, never pushed inside a deal: the recipient
    ///      is the same for every deal, so one the token refuses (a blacklist, a pause) would otherwise stop
    ///      every activation and every terminal at once. `sweepFees` delivers them, and a failed sweep reverts
    ///      alone and leaves the balance owed.
    mapping(address token => uint256 amount) public feesOwed;

    /// @dev A non-zero share needs a recipient. A zero recipient with both shares at zero is a fee-free kernel
    ///      (the test suites; anyone's clone); the official deployment passes the DAO and the shares.
    constructor(address feeRecipient_, uint16 activationBps_, uint16 completionBps_) EIP712("PluriSwap", "2") {
        if (activationBps_ > MAX_KERNEL_BPS || completionBps_ > MAX_KERNEL_BPS) revert BadKernelFee();
        if (feeRecipient_ == address(0) && (activationBps_ != 0 || completionBps_ != 0)) revert BadKernelFee();
        feeRecipient = feeRecipient_;
        activationBps = activationBps_;
        completionBps = completionBps_;
    }

    // --- read ------------------------------------------------------------------------------------------

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function status(bytes32 dealId) external view returns (Status) {
        return deals[dealId].status;
    }

    function settlementOf(bytes32 dealId)
        external
        view
        returns (Status status_, uint256 holderAmt, uint256 providerAmt)
    {
        Deal storage d = deals[dealId];
        return (d.status, d.holderAmt, d.providerAmt);
    }

    function subjects(bytes32 dealId) external view returns (bytes32, bytes32) {
        return (deals[dealId].subjectH, deals[dealId].subjectP);
    }

    function modules(bytes32 dealId) external view returns (PackageMods memory) {
        return deals[dealId].mods;
    }

    function terms(bytes32 dealId) external view returns (DealTerms memory) {
        return deals[dealId].terms;
    }

    function clocks(bytes32 dealId) external view returns (DealClocks memory) {
        Deal storage d = deals[dealId];
        return DealClocks({
            activatedAt: d.activatedAt,
            fiatSentAt: d.fiatSentAt,
            disputedAt: d.disputedAt,
            arbitrationOpenedAt: d.arbitrationOpenedAt
        });
    }

    function kinds(bytes32 dealId) external view returns (uint8) {
        return deals[dealId].pkgs;
    }

    /// @dev The package prices this deal was activated under, and the only ones it is ever charged (Anexo R,
    ///      2026-10-06).
    function pricesOf(bytes32 dealId) external view returns (PackagePrices memory) {
        return deals[dealId].prices;
    }

    /// @dev The post-terminal package calls still owed for a deal, as `Packages.POST_*` bits. Zero means the
    ///      terminal settled cleanly with its packages, or the deal never bound any. Not in `IEscrow`, which
    ///      is the read surface other contracts consume; this one is for keepers and indexers.
    function postPending(bytes32 dealId) external view returns (uint8) {
        return deals[dealId].postPending;
    }

    function contestPaid(bytes32 dealId) external view returns (bool) {
        return deals[dealId].contestPaid;
    }

    function creditOf(address token, address beneficiary) external view returns (uint256) {
        return Settlement.creditOf(settlement, token, beneficiary);
    }

    // --- activation --------------------------------------------------------------------------------------

    function activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig
    ) external nonReentrant returns (bytes32 id) {
        PackageMods memory mods;
        PackageData memory data;
        id = _activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods, data);
    }

    function activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods calldata mods
    ) external nonReentrant returns (bytes32 id) {
        PackageData memory data;
        id = _activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods, data);
    }

    /// @notice Activation with each side's opaque package data (Anexo R, 2026-09-29): what a private side
    ///         needs to be admitted — its proof — travels in the activation itself, so it has nowhere to
    ///         execute without one. The kernel forwards it to the hooks and never reads it.
    function activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods calldata mods,
        PackageData calldata data
    ) external nonReentrant returns (bytes32 id) {
        id = _activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods, data);
    }

    function _activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods memory mods,
        PackageData memory data
    ) internal returns (bytes32 id) {
        DealTerms calldata t = ha.terms;
        bytes32 termsHash = Terms.hashTerms(t);
        if (termsHash != Terms.hashTerms(pa.terms)) revert TermsMismatch();

        if (block.timestamp > ha.deadline || block.timestamp > pa.deadline) revert DeadlinePassed();

        if (!Consent.isValid(t.holder, _hashTypedDataV4(Consent.hashHolderAuthorization(ha)), holderSig)) {
            revert InvalidHolderSignature();
        }
        if (!Consent.isValid(t.provider, _hashTypedDataV4(Consent.hashProviderAgreement(pa)), providerSig)) {
            revert InvalidProviderSignature();
        }

        uint256 controllerNonce;
        if (t.holder != t.controller) {
            if (ca.terms.controller != t.controller) revert ControllerAcceptanceRequired();
            if (termsHash != Terms.hashTerms(ca.terms)) revert TermsMismatch();
            if (block.timestamp > ca.deadline) revert DeadlinePassed();
            if (!Consent.isValid(t.controller, _hashTypedDataV4(Consent.hashControllerAcceptance(ca)), controllerSig)) {
                revert InvalidControllerSignature();
            }
            if (used[t.controller][ca.nonce]) revert NonceUsed();
            controllerNonce = ca.nonce;
        }

        if (used[t.holder][ha.nonce] || used[t.provider][pa.nonce]) revert NonceUsed();

        (uint8 pkgs, PackagePrices memory prices) = Packages.resolve(t.packageIds, t.fiatCommit, mods);
        id = Consent.dealId(_domainSeparatorV4(), t, ha.nonce, pa.nonce, controllerNonce);
        if (deals[id].status != Status.NONE) revert DealExists();

        (bytes32 subjectH, bytes32 subjectP) = Packages.engage(t, pkgs, id, mods, data, prices);
        // The kernel's activation share travels with the principal in one exact pull. It is owed whatever the
        // deal ends in — a cancel included: it is the price of the deal having existed.
        uint256 kernelFee = Packages.share(t.principal, activationBps);
        Settlement.pullExact(t.token, t.holder, t.principal + kernelFee);
        if (kernelFee != 0) {
            feesOwed[t.token] += kernelFee;
            emit Packages.FeeCharged(id, Packages.FeeKind.Activation, feeRecipient, kernelFee);
        }

        used[t.holder][ha.nonce] = true;
        used[t.provider][pa.nonce] = true;
        dealOf[t.holder][ha.nonce] = id;
        dealOf[t.provider][pa.nonce] = id;
        if (t.holder != t.controller) {
            used[t.controller][ca.nonce] = true;
            dealOf[t.controller][ca.nonce] = id;
        }

        Deal storage d = deals[id];
        d.status = Status.FUNDED;
        d.terms = t;
        d.activatedAt = block.timestamp;
        d.subjectH = subjectH;
        d.subjectP = subjectP;
        d.pkgs = pkgs;
        d.mods = mods;
        d.prices = prices;
        emit Transitioned(id, Status.NONE, Status.FUNDED);
        emit Activated(id, t.holder, t.provider, t.controller, t.token, t.principal);
    }

    // --- core verbs ---------------------------------------------------------------------------------------

    function markFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        _requireNotZk(d);
        if (msg.sender != d.terms.provider) revert Unauthorized();
        emit Transitioned(dealId, d.status, Status.FIAT_SENT);
        d.status = Status.FIAT_SENT;
        d.fiatSentAt = block.timestamp;
    }

    function release(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        _close(dealId, d, d.terms.principal, _released());
    }

    function cancelByProvider(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if (msg.sender != d.terms.provider) revert Unauthorized();
        _close(dealId, d, d.terms.principal, _noShow());
    }

    function timeoutFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        Clocks.requireDue(d.activatedAt, d.terms.fiatDuration);
        _close(dealId, d, d.terms.principal, _noShow());
    }

    /// @dev Provider-positive timeout: fiat was sent, the Controller never released. The Provider closed the
    ///      trade and is credited for it; the Holder's side is silent (an absent Controller is not proven fault).
    function claim(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        _requireNotZk(d);
        Clocks.requireDue(d.fiatSentAt, d.terms.releaseDuration);
        _close(
            dealId,
            d,
            d.terms.principal,
            Outcome(Status.CLAIMED, ALL, IReputation.Close.Silent, IReputation.Close.Peaceful, BondAction.Unlock)
        );
    }

    function openDisputed(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        _requireNotZk(d);
        if (msg.sender != d.terms.controller) revert Unauthorized();
        Clocks.requireStrictlyBefore(d.fiatSentAt, d.terms.releaseDuration);
        if ((d.pkgs & (Packages.REP | Packages.ARB)) != 0) Packages.chargeContest(dealId, d, settlement, msg.sender);
        emit Transitioned(dealId, d.status, Status.DISPUTED);
        d.status = Status.DISPUTED;
        d.disputedAt = block.timestamp;
    }

    /// @dev A dispute that ran out its clock. What it means depends on whether the parties gave
    ///      themselves a tribunal (Anexo R, 2026-09-24):
    ///
    ///      * With ARBITRATION selected, the Controller who opened the fight had a court and did not use
    ///        it. Abandoning a fight you could have escalated is losing it: `ABANDONED`, the principal to
    ///        the Provider in full, the locks back (assumed fault, not a verdict), +5 to the opener.
    ///
    ///      * Without it, nobody asked anyone to decide, and neither side gave way — not with a cancel
    ///        (all to the Holder) nor with a co-signed release (all to the Provider), the only agreements
    ///        a dispute leaves open. A deadlock: the principal to `BURN`, both locks to the sink, a
    ///        `Deadlock` close (+10) on both sides. Mutually assured destruction, on purpose: it is what
    ///        makes surrender every cheater's best reply — a liar gets 0 by cancelling and loses his bond
    ///        by waiting; an extortionist gets 0 by releasing and loses hers by waiting — so that trying
    ///        to cheat never pays, even at the price of an honest partner in a genuine disagreement.
    ///        The principal goes credit-first like any payout, so a token that refuses the transfer
    ///        leaves it credited to `BURN` — owned by nobody, which is the same thing.
    function forceDisputeTimeout(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.DISPUTED) revert WrongStatus();
        Clocks.requireDue(d.disputedAt, d.terms.disputeDuration);
        // Abandonment is imputed only to whoever COULD escalate and did not (Anexo R, 2026-09-29): with a
        // court that cannot take the deal, nobody could, and the clock is the no-tribunal deadlock.
        if ((d.pkgs & Packages.ARB) != 0 && Packages.courtAvailable(d, dealId)) {
            _close(
                dealId,
                d,
                d.terms.principal,
                Outcome(
                    Status.ABANDONED,
                    ALL,
                    IReputation.Close.Stalemate, // the opener's side: +5, assumed fault
                    IReputation.Close.Peaceful, // the Provider closed a trade, as in CLAIMED
                    BondAction.Unlock
                )
            );
        } else {
            _deadlock(dealId, d);
        }
    }

    function mutualCancel(
        MutualCancel calldata providerMsg,
        bytes calldata providerSig,
        MutualCancel calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        Deal storage d = deals[providerMsg.dealId];
        _assertLiveForDualSign(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashMutualCancel(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashMutualCancel(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        Outcome memory o = _cancelled();
        o.bond = _bondOnAgreement(d.status);
        _close(providerMsg.dealId, d, d.terms.principal, o);
    }

    function coSignedRelease(
        CoSignedRelease calldata providerMsg,
        bytes calldata providerSig,
        CoSignedRelease calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        Deal storage d = deals[providerMsg.dealId];
        _assertDualSignFromActive(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashCoSignedRelease(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashCoSignedRelease(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        Outcome memory o = _released();
        o.bond = _bondOnAgreement(d.status);
        _close(providerMsg.dealId, d, d.terms.principal, o);
    }

    function mutualSplit(
        MutualSplit calldata providerMsg,
        bytes calldata providerSig,
        MutualSplit calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        if (providerMsg.providerBps != controllerMsg.providerBps) revert BpsMismatch();
        if (providerMsg.providerBps > ALL) revert BpsMismatch();
        Deal storage d = deals[providerMsg.dealId];
        _assertDualSignFromActive(d.status);
        // After a dispute the only agreements are all-or-nothing (cancel, co-signed release). A split there is
        // what the clock's threat extracts — "half, or we both lose it all" — so it is not on offer.
        if (d.status == Status.DISPUTED || d.status == Status.ARBITRATION_ACTIVE) revert SplitAfterDispute();
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashMutualSplit(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashMutualSplit(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        _close(
            providerMsg.dealId,
            d,
            d.terms.principal,
            Outcome(
                Status.RESOLVED_SPLIT,
                providerMsg.providerBps,
                IReputation.Close.Peaceful,
                IReputation.Close.Peaceful,
                BondAction.Unlock
            )
        );
    }

    // --- package verbs --------------------------------------------------------------------------------------

    function verifyProof(bytes32 dealId, bytes calldata proof) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if ((d.pkgs & Packages.ZK) == 0) revert PackageNotSelected();
        (IPaymentProof module, uint256 fee, address to) = Packages.zk(d);
        module.verifyProof(dealId, proof);
        uint256 left = _invoice(dealId, Packages.FeeKind.Proof, d.terms.principal, fee, d.terms.token, to);
        _close(dealId, d, left, _released());
    }

    function openCourt(bytes32 dealId) external payable nonReentrant {
        Deal storage d = deals[dealId];
        if ((d.pkgs & Packages.ARB) == 0) revert PackageNotSelected();
        _requireNotZk(d);
        if (d.status != Status.FIAT_SENT && d.status != Status.DISPUTED) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        if (d.status == Status.FIAT_SENT) {
            Clocks.requireStrictlyBefore(d.fiatSentAt, d.terms.releaseDuration);
            Packages.chargeContest(dealId, d, settlement, msg.sender); // ARB is already required to be here
        } else {
            Clocks.requireStrictlyBefore(d.disputedAt, d.terms.disputeDuration);
        }
        ICourt c = Packages.court(d);
        c.openCourt{value: msg.value}(dealId, msg.sender);
        emit Transitioned(dealId, d.status, Status.ARBITRATION_ACTIVE);
        d.status = Status.ARBITRATION_ACTIVE;
        d.arbitrationOpenedAt = block.timestamp;
    }

    /// @dev 1 = Holder wins (refund, Provider's lock to the Holder), 2 = Provider wins (payout, Holder's lock to
    ///      the Provider) — each minus the court's share of the lock; 3 = the court would not decide: half each,
    ///      each side leaves half the court's share of its own lock, both scores record it.
    function readRuling(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.ARBITRATION_ACTIVE) revert WrongStatus();
        uint8 ruling = ICourt(d.mods.court).readRuling(dealId);
        if (ruling == 1) {
            _close(
                dealId,
                d,
                d.terms.principal,
                Outcome(
                    Status.RESOLVED_BY_ARBITRATION,
                    0,
                    IReputation.Close.ArbWin,
                    IReputation.Close.ArbLoss,
                    BondAction.HolderWins
                )
            );
        } else if (ruling == 2) {
            _close(
                dealId,
                d,
                d.terms.principal,
                Outcome(
                    Status.RESOLVED_BY_ARBITRATION,
                    ALL,
                    IReputation.Close.ArbLoss,
                    IReputation.Close.ArbWin,
                    BondAction.ProviderWins
                )
            );
        } else if (ruling == 3) {
            _close(dealId, d, d.terms.principal, _stalemate(BondAction.Shared, IReputation.Close.Stalemate));
        } else {
            revert NotRuled();
        }
    }

    /// @dev The court never answered. The panel was named at activation and its default ruling needs no vote, so
    ///      this is the rare court that could not rule at all (Anexo R, 2026-09-29, D2): the no-tribunal
    ///      deadlock (OUT-13), so that stretching a court past its clock never buys a half.
    function forceArbitrationTimeout(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.ARBITRATION_ACTIVE) revert WrongStatus();
        Clocks.requireDue(d.arbitrationOpenedAt, d.terms.arbitrationDuration);
        // A court that never ruled is the rare case of an unopenable one, and gets its rule (Anexo R,
        // 2026-09-29): the no-tribunal deadlock, not a half that stretching the court to its clock would buy.
        _deadlock(dealId, d);
    }

    // --- settlement --------------------------------------------------------------------------------------------

    function withdraw(address token) external nonReentrant {
        Settlement.withdraw(settlement, token, msg.sender);
    }

    /// @dev Permissionless: deliver the kernel fees accrued in `token` to `feeRecipient`. Nobody chooses where
    ///      they go — not the caller, not the recipient — so calling it is a chore, not a power.
    function sweepFees(address token) external nonReentrant {
        uint256 amount = feesOwed[token];
        if (amount == 0) return;
        feesOwed[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, amount);
        emit FeesSwept(token, feeRecipient, amount);
    }

    /// @dev Permissionless retry of the post-terminal package calls that failed inside `_close`. Without it a
    ///      module that was merely unreachable at the terminal -- a proxy mid-upgrade, a paused
    ///      implementation -- costs its subjects permanently: `Reputation.inFlight` stays consumed for a deal
    ///      that already closed, and `BondVault.lockOf` keeps `available` reduced so a bond that was deposited
    ///      and earned back can never be withdrawn. Only the escrow can make these calls, since both modules
    ///      gate on `msg.sender == operator`, so the retry has to live here.
    ///      Idempotent: `Packages.runPostTerminal` clears a bit only when its own call succeeds, so retrying
    ///      can never apply a reputation delta twice or dispose the same lock twice.
    function retryPostTerminal(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (!isTerminal(d.status)) revert WrongStatus();
        uint8 pending = d.postPending;
        if (pending == 0) revert NothingPending();
        uint8 left = Packages.runPostTerminal(d, dealId, d.closeH, d.closeP, d.bondAction, pending);
        d.postPending = left;
        emit PostTerminalPending(dealId, left);
    }

    function cancelNonce(uint256 nonce) external {
        used[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    // --- internals -------------------------------------------------------------------------------------------------

    function _released() private pure returns (Outcome memory) {
        return Outcome(Status.RELEASED, ALL, IReputation.Close.Peaceful, IReputation.Close.Peaceful, BondAction.Unlock);
    }

    function _cancelled() private pure returns (Outcome memory) {
        return Outcome(Status.CANCELLED, 0, IReputation.Close.Silent, IReputation.Close.Silent, BondAction.Unlock);
    }

    /// @dev An agreement reached while the court was open used the court (Anexo R, 2026-10-05): each side leaves
    ///      half the court's share of its own lock. Anywhere else nobody was asked, and the locks come back whole.
    function _bondOnAgreement(Status s) private pure returns (BondAction) {
        return s == Status.ARBITRATION_ACTIVE ? BondAction.Shared : BondAction.Unlock;
    }

    /// @dev The no-tribunal branch (OUT-13): the principal to `BURN`, both locks to the sink, `Deadlock` on both.
    function _deadlock(bytes32 dealId, Deal storage d) private {
        uint256 principal = d.terms.principal;
        emit PrincipalBurned(dealId, principal);
        Settlement.creditThenTryPush(settlement, d.terms.token, BURN, principal);
        _close(dealId, d, 0, _stalemate(BondAction.Burn, IReputation.Close.Deadlock));
    }

    /// @dev A Provider who never showed up (Anexo R, 2026-09-28): the Holder is refunded and marked nothing;
    ///      the Provider's side closes `NoShow` (+5). The activation fee the Holder paid is not refunded, so
    ///      without this mark accepting and never paying would cost the Holder and not the Provider. The
    ///      mutual cancel keeps `_cancelled`: it is the honest Provider's free exit, and it needs the Holder.
    function _noShow() private pure returns (Outcome memory) {
        return Outcome(Status.CANCELLED, 0, IReputation.Close.Silent, IReputation.Close.NoShow, BondAction.Unlock);
    }

    function _stalemate(BondAction bond, IReputation.Close close) private pure returns (Outcome memory) {
        return Outcome(Status.STALEMATE, HALF, close, close, bond);
    }

    /// @dev One exit for every terminal. The completion fees -- the kernel's, then the reputation package's --
    ///      are invoiced on the whole principal whenever any of the pot reaches the Provider *and the terminal
    ///      is not a stalemate*, before the split. A refund, a 50/50 stalemate and a deadlock burn are never
    ///      invoiced: there was no completion, and the DAO must never gain from a deal that failed.
    ///      KERNEL-04: a fee that does not fit is skipped, a terminal never reverts on a package.
    function _close(bytes32 dealId, Deal storage d, uint256 pot, Outcome memory o) internal {
        uint256 providerAmt = pot * o.providerBps / ALL;
        // A stalemate is not a completion: nobody closed a trade. Invoicing it would pay the fee
        // recipient for an abandoned fight.
        if (providerAmt != 0 && o.next != Status.STALEMATE) {
            pot = _accrue(dealId, pot, Packages.share(d.terms.principal, completionBps), d.terms.token);
            (uint256 fee, address to) = Packages.completionInvoice(d);
            pot = _invoice(dealId, Packages.FeeKind.Completion, pot, fee, d.terms.token, to);
            providerAmt = pot * o.providerBps / ALL;
        }
        uint256 holderAmt = pot - providerAmt;

        emit Transitioned(dealId, d.status, o.next);
        d.status = o.next;
        d.holderAmt = holderAmt;
        d.providerAmt = providerAmt;
        emit Settled(dealId, o.next, holderAmt, providerAmt);
        if (holderAmt != 0) Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, holderAmt);
        if (providerAmt != 0) Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, providerAmt);

        // Post-terminal package work. KERNEL-04 keeps it off the critical path -- a call that fails here does
        // not revert the terminal -- but `_close` is one-shot, so a failure has to be retryable from stored
        // state or it is lost forever: an undelivered `notifyTerminal` leaves `Reputation.inFlight` consumed
        // for a deal that already closed, and an undisposed bond leaves real deposited value locked, since
        // `available` subtracts it. Store the outcome and the outstanding bits only when something is still
        // owed, so Core-only deals and clean terminals pay nothing for the retry path.
        uint8 owed = Packages.postTerminalOwed(d, o.bond);
        if (owed != 0) {
            uint8 left = Packages.runPostTerminal(d, dealId, uint8(o.closeH), uint8(o.closeP), uint8(o.bond), owed);
            if (left != 0) {
                d.closeH = uint8(o.closeH);
                d.closeP = uint8(o.closeP);
                d.bondAction = uint8(o.bond);
                d.postPending = left;
                emit PostTerminalPending(dealId, left);
            }
        }
    }

    /// @dev KERNEL-04: a fee that does not fit is skipped and the terminal never reverts on a package.
    ///      "Does not fit" is `fee >= left`, not `fee > left`. The completion fee is consideration for a
    ///      settlement that succeeded, so a fee that consumes the whole pot is self-defeating: it would leave
    ///      the side that just closed the trade, won the ruling or outlasted the clock with nothing, and turn
    ///      the terminal into a pure transfer to the fee recipient. Skipping at equality keeps the invariant
    ///      that a package can reduce a Core outcome but never annul it.
    ///      The payout is still not monotone in the fee at the boundary -- `fee == left - 1` leaves the winner
    ///      one unit while `fee == left` leaves them the whole pot -- so no fee can now confiscate a win, but a
    ///      fee just under the principal still nearly does. That residual is a consent-disclosure problem: the
    ///      fee is inside the signed `packageId`, and clients are expected to show net proceeds before signing.
    function _invoice(bytes32 dealId, Packages.FeeKind kind, uint256 left, uint256 fee, address token, address to)
        internal
        returns (uint256)
    {
        if (fee == 0 || fee >= left) return left;
        left -= fee;
        Settlement.creditThenTryPush(settlement, token, to, fee);
        emit Packages.FeeCharged(dealId, kind, to, fee);
        return left;
    }

    /// @dev The kernel's completion share, under `_invoice`'s rule (a fee that does not fit is skipped), accrued
    ///      for `sweepFees` instead of pushed.
    function _accrue(bytes32 dealId, uint256 left, uint256 fee, address token) internal returns (uint256) {
        if (fee == 0 || fee >= left) return left;
        feesOwed[token] += fee;
        emit Packages.FeeCharged(dealId, Packages.FeeKind.Completion, feeRecipient, fee);
        return left - fee;
    }

    function _requireNotZk(Deal storage d) internal view {
        if ((d.pkgs & Packages.ZK) != 0) revert EdgeOff();
    }

    function _assertDualSignEnvelope(bytes32 dealIdA, uint256 deadlineA, bytes32 dealIdB, uint256 deadlineB)
        private
        view
    {
        if (dealIdA != dealIdB) revert DealIdMismatch();
        if (deadlineA != deadlineB) revert DeadlineMismatch();
        if (block.timestamp > deadlineA) revert DeadlinePassed();
    }

    function _assertLiveForDualSign(Status s) private pure {
        if (s != Status.FUNDED && s != Status.FIAT_SENT && s != Status.DISPUTED && s != Status.ARBITRATION_ACTIVE) {
            revert WrongStatus();
        }
    }

    function _assertDualSignFromActive(Status s) private pure {
        if (s != Status.FIAT_SENT && s != Status.DISPUTED && s != Status.ARBITRATION_ACTIVE) revert WrongStatus();
    }

    function _consumeDualSign(
        address provider,
        bytes32 providerDigest,
        bytes calldata providerSig,
        uint256 providerNonce,
        address controller,
        bytes32 controllerDigest,
        bytes calldata controllerSig,
        uint256 controllerNonce
    ) private {
        if (!Consent.isValid(provider, providerDigest, providerSig)) {
            revert InvalidProviderSignature();
        }
        if (!Consent.isValid(controller, controllerDigest, controllerSig)) revert InvalidControllerSignature();
        if (used[provider][providerNonce] || used[controller][controllerNonce]) revert NonceUsed();
        used[provider][providerNonce] = true;
        used[controller][controllerNonce] = true;
    }
}
