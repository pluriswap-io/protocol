// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DealTerms, HolderAuthorization, PackageMods, Status, isTerminal} from "../libraries/Types.sol";
import {Consent} from "../libraries/Consent.sol";
import {Settlement} from "../libraries/Settlement.sol";
import {IEscrow} from "../interfaces/IEscrow.sol";
import {IReputation} from "../packages/interfaces/IReputation.sol";
import {ICourt} from "../packages/interfaces/ICourt.sol";
import {IPoolBonds} from "../packages/interfaces/IPoolBonds.sol";
import {IPoolOperators} from "../packages/interfaces/IPoolOperators.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {Packages} from "../libraries/Packages.sol";

/// @dev The one kernel verb a pool needs beyond the read surface: fetching a payout the escrow could not push.
interface IEscrowCredit {
    function withdraw(address token) external;
}

/// @dev A court that pays what it owes on request (ArbiterRegistry).
interface ICourtCredit {
    function withdrawCredit() external;
}

contract Pool is ReentrancyGuardTransient, IPoolOperators {
    using SafeERC20 for IERC20;

    bytes4 internal constant MAGIC = 0x1626ba7e;
    uint256 internal constant MIN_FIRST = 1e6;
    uint256 internal constant BPS_DENOM = 10_000;

    enum Life {
        NONE,
        ACTIVE,
        DEFICIENT,
        RUNOFF,
        WINDING_DOWN,
        CLOSED
    }

    error AlreadyInitialized();
    error Unauthorized();
    error WrongLife();
    error BadTerms();
    error InsufficientIdle();
    error AuthExists();
    error NoAuth();
    error StillLive();
    error NonceConsumed();
    error DeadlineActive();
    error BadReturn();
    error Duplicate();
    error FirstDepositTooSmall();
    error InsufficientShares();
    error RedeemExceedsIdle();
    error BadFee();
    error IsSponsor();
    error EmptySponsors();
    error EmptyDepositors();
    error OpenHasDepositors();
    error ZeroNav();
    error FightInFlight();
    error OverLimit();
    error CourtRequired();
    error OperatorUnregistered();
    error WrongVault();

    struct Auth {
        bytes32 digest;
        DealTerms terms;
        uint256 deadline;
        address controller;
        uint256 fee;
        uint256 activationFee;
        uint256 contestReserve;
        bool exists;
        bool unlocked;
        bool reconciled;
        bool activated;
        bool recognized;
    }

    bool public initialized;
    address public token;
    address public escrow;
    Life public life;
    bool public openDeposits;
    uint16 public controllerFeeBps;
    /// @dev When true, `authorize` reserves the contest-open due and `reconcile` pays it to the Controller
    ///      if they opened a fight (they already paid the kernel from their wallet). When false, the
    ///      Controller eats that cost — their skin in the game.
    bool public reimburseContest;
    /// @dev When true, the reserved Controller fee is paid even if the Holder got the whole principal back.
    ///      When false (default), a full refund returns the reserve to idle: no trade, no desk cut.
    bool public payControllerOnFullReturn;
    uint256 public idle;
    uint256 public locked;
    uint256 public consumed;
    uint256 public credits;
    uint256 public totalShares;
    /// @dev The Sponsor's bounds on what the pool's signature can commit (evaluation of 2026-09-28): the largest
    ///      principal of one deal, the most one Controller may have open at once (0 = no bound), and whether every
    ///      deal must carry a tribunal — without one, a fight nobody settles burns the LPs' principal.
    uint256 public maxPrincipal;
    uint256 public maxControllerExposure;
    bool public requireCourt;
    mapping(address controller => uint256) public controllerOpen;
    /// @dev A second digest an auth may answer for: the panel appointment of its deal (Anexo R, 2026-09-28),
    ///      which the Holder — this pool — signs. Registered by the auth's Controller or a Sponsor.
    mapping(bytes32 digest => uint256 nonce) public courtNonceOf;
    mapping(bytes32 digest => bool) public courtApproved;
    /// @dev Who acts for the pool (Anexo R, 2026-10-05): each agent's operator tag, `H(sk_id, pool)` of the verified
    ///      account behind it. The private passport requires a pool's side to be the vouch of the human whose tag is
    ///      registered here for the deal's Controller. The wallet becomes public as an operator of this pool; the
    ///      account behind it does not.
    mapping(address operator => bytes32 tag) public operatorTagOf;
    /// @dev The vault the pool's bond lives in, fixed by the first `fundBond` (Anexo R, 2026-10-05). The pool is a peer
    ///      with a bond of its own, out of its own capital, and the bond is the LPs' money: it counts in the NAV.
    address public bondVault;

    mapping(address account => bool) public sponsors;
    mapping(address account => bool) public designated;
    mapping(address account => bool) public allowedDepositor;
    mapping(address account => uint256) public sharesOf;
    mapping(uint256 nonce => Auth) public auths;
    mapping(bytes32 digest => uint256 nonce) public nonceOf;
    mapping(uint256 nonce => uint256 indexPlusOne) internal liveAt;
    uint256[] internal liveNonces;

    Settlement.Store internal payables;

    constructor() {
        initialized = true;
    }

    function initialize(
        address[] calldata sponsors_,
        address token_,
        address escrow_,
        address[] calldata controllers_,
        bool openDeposits_,
        address[] calldata depositors_,
        uint16 controllerFeeBps_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (token_ == address(0) || escrow_ == address(0)) revert BadTerms();
        if (sponsors_.length == 0) revert EmptySponsors();
        if (controllerFeeBps_ > BPS_DENOM) revert BadFee();
        if (openDeposits_) {
            if (depositors_.length != 0) revert OpenHasDepositors();
        } else if (depositors_.length == 0) {
            revert EmptyDepositors();
        }
        _unique(sponsors_);
        if (!openDeposits_) _unique(depositors_);

        initialized = true;
        token = token_;
        escrow = escrow_;
        openDeposits = openDeposits_;
        controllerFeeBps = controllerFeeBps_;
        life = Life.ACTIVE;

        for (uint256 i; i < sponsors_.length; i++) {
            sponsors[sponsors_[i]] = true;
        }
        for (uint256 i; i < controllers_.length; i++) {
            address c = controllers_[i];
            if (c == address(0) || sponsors[c]) revert BadTerms();
            designated[c] = true;
        }
        if (!openDeposits_) {
            for (uint256 i; i < depositors_.length; i++) {
                allowedDepositor[depositors_[i]] = true;
            }
        }
    }

    function isAgent(address account) public view returns (bool) {
        return sponsors[account] || designated[account];
    }

    /// @dev Holder-gross already terminal sits in `credits` (or is previewed here via `dealOf`). The bond is read live
    ///      from its vault: a lock lost in a dispute, or the counterparty's won, moves the NAV the moment it moves.
    function nav() public view returns (uint256) {
        (uint256 idle_, uint256 credits_, uint256 locked_) = _books();
        return idle_ + credits_ + locked_ + bonded();
    }

    /// @notice The pool's bond, free and locked, in its vault.
    function bonded() public view returns (uint256) {
        if (bondVault == address(0)) return 0;
        return IPoolBonds(bondVault).poolBondOf(address(this), token);
    }

    function controllerCredit(address account) external view returns (uint256) {
        return Settlement.creditOf(payables, token, account);
    }

    function setController(address controller, bool allowed) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (sponsors[controller] || controller == address(0)) revert IsSponsor();
        designated[controller] = allowed;
    }

    event OperatorTagSet(address indexed operator, bytes32 tag);
    event BondFunded(address indexed vault, uint256 amount);
    event BondWithdrawn(address indexed vault, uint256 amount);

    /// @notice An agent registers the operator tag of the verified account it acts with. Zero clears it.
    function setOperatorTag(bytes32 tag) external {
        if (!isAgent(msg.sender)) revert Unauthorized();
        operatorTagOf[msg.sender] = tag;
        emit OperatorTagSet(msg.sender, tag);
    }

    /// @notice Moves `amount` of idle capital into the pool's bond in `vault`. A Sponsor's call; the first one fixes
    ///         the vault. The NAV does not move: the bond is the LPs' money in another place.
    function fundBond(address vault, uint256 amount) external nonReentrant {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (vault == address(0) || (bondVault != address(0) && vault != bondVault)) revert WrongVault();
        if (amount == 0) revert BadTerms();
        _recognizeLive();
        if (idle < amount) revert InsufficientIdle();
        bondVault = vault;
        idle -= amount;
        IERC20(token).forceApprove(vault, amount);
        IPoolBonds(vault).depositPool(address(this), token, amount);
        emit BondFunded(vault, amount);
        _sync();
    }

    /// @notice Brings `amount` of the pool's free bond back into idle. A Sponsor's call; only what arrives is booked.
    function withdrawBond(uint256 amount) external nonReentrant {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (bondVault == address(0)) revert WrongVault();
        uint256 before = IERC20(token).balanceOf(address(this));
        IPoolBonds(bondVault).withdrawPool(token, amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        idle += received;
        emit BondWithdrawn(bondVault, received);
        _sync();
    }

    function setControllerFeeBps(uint16 bps) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (bps > BPS_DENOM) revert BadFee();
        controllerFeeBps = bps;
    }

    function setReimburseContest(bool on) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        reimburseContest = on;
    }

    function setPayControllerOnFullReturn(bool on) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        payControllerOnFullReturn = on;
    }

    /// @notice The Sponsor's bounds on what one signature can commit. Future authorizations only.
    function setLimits(uint256 maxPrincipal_, uint256 maxControllerExposure_, bool requireCourt_) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        maxPrincipal = maxPrincipal_;
        maxControllerExposure = maxControllerExposure_;
        requireCourt = requireCourt_;
    }

    function deposit(uint256 amount) external nonReentrant {
        _recognizeLive();
        // While a deal is in a fight the NAV prices a principal the pool may lose: a newcomer would buy into that
        // loss at full price, and a leaver would hand it to the ones who stay.
        if (_fightLive()) revert FightInFlight();
        if (life != Life.ACTIVE && life != Life.DEFICIENT) revert WrongLife();
        if (!openDeposits && !allowedDepositor[msg.sender]) revert Unauthorized();
        if (amount == 0) revert BadTerms();

        uint256 onHand = IERC20(token).balanceOf(address(this)) + IEscrow(escrow).creditOf(token, address(this));
        uint256 accounted = idle + credits;
        uint256 hole = onHand < accounted ? accounted - onHand : 0;
        uint256 invest = amount > hole ? amount - hole : 0;

        uint256 minted;
        if (invest != 0) {
            if (totalShares == 0) {
                if (invest < MIN_FIRST) revert FirstDepositTooSmall();
                minted = invest;
            } else {
                uint256 n = nav();
                if (n == 0) revert ZeroNav();
                minted = invest * totalShares / n;
                if (minted == 0) revert FirstDepositTooSmall();
            }
        }

        Settlement.pullExact(token, msg.sender, amount);
        idle += invest;
        sharesOf[msg.sender] += minted;
        totalShares += minted;
        _sync();
    }

    function redeem(uint256 sharesIn) external nonReentrant {
        _recognizeLive();
        if (_fightLive()) revert FightInFlight();
        if (life != Life.ACTIVE && life != Life.RUNOFF && life != Life.WINDING_DOWN) revert WrongLife();
        if (sharesIn == 0 || sharesIn > sharesOf[msg.sender]) revert InsufficientShares();
        uint256 n = nav();
        uint256 assetsOut = sharesIn * n / totalShares;
        if (n == 0) {
            // Books empty: a share is not a claim on idle (there is none). Burn so the vault can
            // close or take a new first deposit. Surplus token sitting off-book is recap buffer, not NAV.
        } else {
            if (assetsOut > idle) revert RedeemExceedsIdle();
            if (assetsOut == 0) revert InsufficientShares();
        }

        sharesOf[msg.sender] -= sharesIn;
        totalShares -= sharesIn;
        idle -= assetsOut;
        if (assetsOut != 0) IERC20(token).safeTransfer(msg.sender, assetsOut);
        _maybeClose();
        _sync();
    }

    function withdrawCredit() external nonReentrant {
        Settlement.withdraw(payables, token, msg.sender);
    }

    /// @notice Fetches a payout the escrow could not push to this pool (a paused or blacklisting token). The books
    ///         already count it — `_onHand` includes the escrow credit — so this moves it, it does not create it.
    function pullEscrowCredit() external nonReentrant {
        IEscrowCredit(escrow).withdraw(token);
        _sync();
    }

    /// @notice Fetches what a court owes this pool as Holder — an unearned availability fee coming back, or an
    ///         abstaining arbiter's slash — into idle: it is the LPs' money. An agent's call, because it runs the
    ///         named contract's code; only the balance that actually arrives is booked.
    function pullCourtCredit(address court) external nonReentrant {
        if (!isAgent(msg.sender)) revert Unauthorized();
        uint256 before = IERC20(token).balanceOf(address(this));
        ICourtCredit(court).withdrawCredit();
        idle += IERC20(token).balanceOf(address(this)) - before;
        _sync();
    }

    /// @notice Lets auth `nonce` answer for its deal's panel appointment as well (Anexo R, 2026-09-28): the Holder
    ///         signs the panel, and the Holder is this pool.
    function approveCourtDigest(uint256 nonce, bytes32 digest) external {
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        if (msg.sender != a.controller && !sponsors[msg.sender]) revert Unauthorized();
        courtNonceOf[digest] = nonce;
        courtApproved[digest] = true;
    }

    function sync() external nonReentrant {
        _recognizeLive();
        _sync();
    }

    function startRunoff() external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.ACTIVE && life != Life.DEFICIENT) revert WrongLife();
        life = Life.RUNOFF;
    }

    function endRunoff() external nonReentrant {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.RUNOFF) revert WrongLife();
        _recognizeLive();
        if (locked != 0) revert StillLive();
        life = totalShares == 0 ? Life.CLOSED : Life.ACTIVE;
    }

    function windDown() external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.ACTIVE && life != Life.DEFICIENT && life != Life.RUNOFF) revert WrongLife();
        life = Life.WINDING_DOWN;
        _maybeClose();
    }

    /// @dev Reserve pool capital for a deal the Controller is about to activate. `mods` must name every module
    ///      the signed `ha.terms.packageIds` refers to, exactly as `Escrow.activate` will require: the pool
    ///      runs the same `Packages.resolve`, so a deal that carries REPUTATION cannot be authorized as if it
    ///      did not. That matters because the kernel pulls its own activation share, and `Packages.engage` the
    ///      packages', from the Holder -- this pool -- on top of the principal, and `_refreshApprove` sizes the escrow allowance as the exact sum
    ///      of `principal + activationFee` over live auths. An auth that reserved no fee either cannot
    ///      activate, or spends another auth's share of that aggregate allowance and leaves the vault short.
    ///      Resolving here turns that from an accounting repair into an impossible state.
    ///      Core-only deals pass an all-zero `PackageMods`, which `resolve` accepts against empty `packageIds`.
    function authorize(HolderAuthorization calldata ha, PackageMods calldata mods) external nonReentrant {
        _authorize(ha, mods);
    }

    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        uint256 nonce = nonceOf[digest];
        Auth storage a = auths[nonce];
        if (a.digest != digest) {
            if (!courtApproved[digest]) return bytes4(0);
            a = auths[courtNonceOf[digest]];
        }
        if (!a.exists || a.unlocked || a.reconciled) return bytes4(0);
        // POOLS.md: only ACTIVE validates digests; kick cuts pending auths (future-only vs live deals).
        if (life != Life.ACTIVE) return bytes4(0);
        if (!isAgent(a.controller)) return bytes4(0);
        return MAGIC;
    }

    function unlock(uint256 nonce) external nonReentrant {
        _recognizeLive();
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        if (IEscrow(escrow).used(address(this), nonce)) revert NonceConsumed();
        // Same predicate as `isValidSignature`: if the digest would no longer validate, the
        // reservation is dead and capital must not wait out a long HA deadline (kick, runoff).
        bool digestDead = life != Life.ACTIVE || !isAgent(a.controller);
        if (!digestDead && block.timestamp <= a.deadline) revert DeadlineActive();
        a.unlocked = true;
        delete nonceOf[a.digest];
        uint256 amt = a.terms.principal + a.fee + a.activationFee + a.contestReserve;
        locked -= amt;
        idle += amt;
        controllerOpen[a.controller] -= a.terms.principal;
        _popLive(nonce);
        _refreshApprove();
        _maybeClose();
        _sync();
    }

    function reconcile(uint256 nonce) external nonReentrant {
        _recognizeLive();
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        bytes32 id = IEscrow(escrow).dealOf(address(this), nonce);
        if (id == 0) revert StillLive();
        (Status st, uint256 returned, uint256 paid) = IEscrow(escrow).settlementOf(id);
        if (!isTerminal(st)) revert StillLive();
        if (returned > a.terms.principal) revert BadReturn();
        if (!a.recognized) _applyTerminal(a, returned);
        // A deadlock burned the principal: nobody is paid a desk fee for letting the LPs' money burn.
        bool burned = st == Status.STALEMATE && returned == 0 && paid == 0;

        uint256 onHand = _onHand();
        if (onHand < idle + credits) revert BadReturn();

        a.reconciled = true;
        delete nonceOf[a.digest];
        credits -= returned;
        locked -= a.fee;
        consumed += a.terms.principal - returned;
        idle += returned;
        bool feeEarned = a.fee != 0 && !burned && (returned < a.terms.principal || payControllerOnFullReturn);
        controllerOpen[a.controller] -= a.terms.principal;
        if (feeEarned) {
            consumed += a.fee;
            Settlement.creditThenTryPush(payables, token, a.controller, a.fee);
        } else {
            idle += a.fee;
        }
        if (a.contestReserve != 0) {
            locked -= a.contestReserve;
            if (IEscrow(escrow).contestPaid(id)) {
                consumed += a.contestReserve;
                Settlement.creditThenTryPush(payables, token, a.controller, a.contestReserve);
            } else {
                idle += a.contestReserve;
            }
        }
        _popLive(nonce);
        _refreshApprove();
        _maybeClose();
        _sync();
    }

    function _authorize(HolderAuthorization calldata ha, PackageMods calldata mods) internal {
        _recognizeLive();
        if (life != Life.ACTIVE) revert WrongLife();
        DealTerms calldata t = ha.terms;
        if (t.holder != address(this) || t.token != token || t.principal == 0) revert BadTerms();
        if (!isAgent(t.controller)) revert Unauthorized();
        if (msg.sender != t.controller && !sponsors[msg.sender]) revert Unauthorized();
        if (block.timestamp > ha.deadline) revert DeadlineActive();
        if (IEscrow(escrow).used(address(this), ha.nonce)) revert NonceConsumed();
        Auth storage a = auths[ha.nonce];
        if (a.exists && !a.unlocked && !a.reconciled) revert AuthExists();

        // The kernel's own resolution, run before anything is reserved. Every signed id must be matched to a
        // named module, so `mods.reputation == address(0)` on a deal that carries REPUTATION reverts here
        // instead of becoming an unpriced reservation. Fail closed while nothing has moved yet.
        Packages.resolve(t.packageIds, t.fiatCommit, mods);
        if (maxPrincipal != 0 && t.principal > maxPrincipal) revert OverLimit();
        if (maxControllerExposure != 0 && controllerOpen[t.controller] + t.principal > maxControllerExposure) {
            revert OverLimit();
        }
        if (requireCourt && mods.court == address(0)) revert CourtRequired();
        // A deal the passport identifies is acted through a proven operator (Anexo R, 2026-10-05): a Controller
        // without a registered operator tag could never produce the vouch, so it is not authorized either.
        if (mods.passport != address(0) && operatorTagOf[t.controller] == bytes32(0)) revert OperatorUnregistered();

        uint256 fee = t.principal * uint256(controllerFeeBps) / BPS_DENOM;
        // The kernel's activation share is owed by every deal, packages or not; the packages' come on top.
        uint256 actFee = Packages.share(t.principal, IEscrow(escrow).activationBps())
            + (mods.reputation == address(0) ? 0 : _activationFee(t, mods.reputation))
            + (mods.court == address(0) ? 0 : _courtShare(t, mods.court));
        uint256 contest = (reimburseContest && mods.reputation != address(0)) ? _contestDue(t, mods.reputation) : 0;
        if (idle < t.principal + fee + actFee + contest) revert InsufficientIdle();

        bytes32 digest = _digest(ha);
        idle -= t.principal + fee + actFee + contest;
        locked += t.principal + fee + actFee + contest;
        a.digest = digest;
        a.terms = t;
        a.deadline = ha.deadline;
        a.controller = t.controller;
        a.fee = fee;
        a.activationFee = actFee;
        a.contestReserve = contest;
        a.exists = true;
        a.unlocked = false;
        a.reconciled = false;
        a.activated = false;
        a.recognized = false;
        nonceOf[digest] = ha.nonce;
        controllerOpen[t.controller] += t.principal;
        _pushLive(ha.nonce);
        _refreshApprove();
    }

    /// @dev The activation fee to reserve. `Packages.resolve` has already proved this module hashes to a
    ///      signed id, so recomputing it here is a second line of defence rather than the first: it catches a
    ///      module that answers `feeRecipient`/`activationBps`/`completionBps` differently between the two
    ///      reads inside this same transaction. PERM-03 lets anyone publish a module, so that is not
    ///      hypothetical. `BadTerms` here means the reservation would not match what the kernel will pull.
    function _activationFee(DealTerms calldata t, address reputation) internal view returns (uint256) {
        if (reputation == address(0)) return 0;
        IReputation r = IReputation(reputation);
        bytes32 id = PackageId.reputation(
            reputation, r.feeRecipient(), r.activationBps(), r.completionBps(), r.contestBps(), r.contestFloor()
        );
        bytes32[] calldata ids = t.packageIds;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return Packages.share(t.principal, r.activationBps());
        }
        revert BadTerms();
    }

    /// @dev The court's availability share, which the kernel pulls from the Holder — this pool — at activation,
    ///      re-bound to a signed id exactly as `_activationFee` re-binds the reputation's.
    function _courtShare(DealTerms calldata t, address court) internal view returns (uint256) {
        ICourt c = ICourt(court);
        (address partner, uint256 key) = c.packageBinding();
        uint256 bps = c.activationBps();
        bytes32 id = PackageId.arbitration(court, partner, key, c.contestFee(), c.feeRecipient(), bps, c.bondShareBps());
        bytes32[] calldata ids = t.packageIds;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return Packages.share(t.principal, bps);
        }
        revert BadTerms();
    }

    /// @notice Whether deposits and redemptions are frozen because a live deal is in a fight.
    function fightInFlight() external view returns (bool) {
        return _fightLive();
    }

    /// @dev Whether any live deal of this pool is in a fight: disputed, or before a court.
    function _fightLive() internal view returns (bool) {
        IEscrow kernel = IEscrow(escrow);
        uint256 n = liveNonces.length;
        for (uint256 i; i < n; i++) {
            bytes32 id = kernel.dealOf(address(this), liveNonces[i]);
            if (id == 0) continue;
            Status st = kernel.status(id);
            if (st == Status.DISPUTED || st == Status.ARBITRATION_ACTIVE) return true;
        }
        return false;
    }

    function _contestDue(DealTerms calldata t, address reputation) internal view returns (uint256) {
        if (reputation == address(0)) return 0;
        IReputation r = IReputation(reputation);
        bytes32 id = PackageId.reputation(
            reputation, r.feeRecipient(), r.activationBps(), r.completionBps(), r.contestBps(), r.contestFloor()
        );
        bytes32[] calldata ids = t.packageIds;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return Packages.contestDue(t.principal, r.contestBps(), r.contestFloor());
        }
        revert BadTerms();
    }

    function _digest(HolderAuthorization calldata ha) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(IEscrow(escrow).domainSeparator(), Consent.hashHolderAuthorization(ha));
    }

    function _onHand() internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) + IEscrow(escrow).creditOf(token, address(this));
    }

    function _books() internal view returns (uint256 idle_, uint256 credits_, uint256 locked_) {
        idle_ = idle;
        credits_ = credits;
        locked_ = locked;
        IEscrow kernel = IEscrow(escrow);
        uint256 n = liveNonces.length;
        for (uint256 i; i < n; i++) {
            uint256 nonce = liveNonces[i];
            Auth storage a = auths[nonce];
            if (a.unlocked || a.reconciled) continue;
            bytes32 id = kernel.dealOf(address(this), nonce);
            if (id == 0) continue;
            if (!a.activated) locked_ -= a.activationFee;
            if (a.recognized) continue;
            (Status st, uint256 returned,) = kernel.settlementOf(id);
            if (!isTerminal(st)) continue;
            locked_ -= a.terms.principal;
            credits_ += returned;
        }
    }

    function _recognizeLive() internal {
        IEscrow kernel = IEscrow(escrow);
        uint256 n = liveNonces.length;
        bool dirty;
        for (uint256 i; i < n; i++) {
            uint256 nonce = liveNonces[i];
            Auth storage a = auths[nonce];
            if (a.unlocked || a.reconciled) continue;
            bytes32 id = kernel.dealOf(address(this), nonce);
            if (id == 0) continue;
            if (!a.activated) {
                // There is deliberately no repair branch for an unreserved activation fee. `authorize` runs
                // `Packages.resolve` and `_activationFee` re-binds the policy to a signed id, and
                // `Packages.engage` pulls the copy `resolve` bound to that same id, so what was reserved and what
                // the kernel takes cannot diverge. A shortfall here would mean one of those three checks is broken, and
                // `_sync` is the net that reports it rather than this loop papering over it.
                if (a.activationFee != 0) {
                    locked -= a.activationFee;
                    consumed += a.activationFee;
                }
                a.activated = true;
                dirty = true;
            }
            if (a.recognized) continue;
            (Status st, uint256 returned,) = kernel.settlementOf(id);
            if (!isTerminal(st)) continue;
            _applyTerminal(a, returned);
            dirty = true;
        }
        if (dirty) _refreshApprove();
    }

    function _applyTerminal(Auth storage a, uint256 returned) internal {
        locked -= a.terms.principal;
        credits += returned;
        a.recognized = true;
    }

    function _refreshApprove() internal {
        uint256 need;
        IEscrow kernel = IEscrow(escrow);
        uint256 n = liveNonces.length;
        for (uint256 i; i < n; i++) {
            uint256 nonce = liveNonces[i];
            Auth storage a = auths[nonce];
            if (a.unlocked || a.reconciled || a.activated) continue;
            if (kernel.used(address(this), nonce)) continue;
            need += a.terms.principal + a.activationFee;
        }
        IERC20(token).forceApprove(escrow, need);
    }

    function _pushLive(uint256 nonce) internal {
        if (liveAt[nonce] != 0) return;
        liveNonces.push(nonce);
        liveAt[nonce] = liveNonces.length;
    }

    function _popLive(uint256 nonce) internal {
        uint256 i = liveAt[nonce];
        if (i == 0) return;
        uint256 last = liveNonces[liveNonces.length - 1];
        liveNonces[i - 1] = last;
        liveAt[last] = i;
        liveNonces.pop();
        delete liveAt[nonce];
    }

    function _sync() internal {
        if (life != Life.ACTIVE && life != Life.DEFICIENT) return;
        if (_onHand() < idle + credits) life = Life.DEFICIENT;
        else if (life == Life.DEFICIENT) life = Life.ACTIVE;
    }

    function _maybeClose() internal {
        if (life != Life.RUNOFF && life != Life.WINDING_DOWN) return;
        if (locked == 0 && totalShares == 0) life = Life.CLOSED;
    }

    function _unique(address[] calldata xs) internal pure {
        for (uint256 i; i < xs.length; i++) {
            if (xs[i] == address(0)) revert BadTerms();
            for (uint256 j; j < i; j++) {
                if (xs[i] == xs[j]) revert Duplicate();
            }
        }
    }
}
