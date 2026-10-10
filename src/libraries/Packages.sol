// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Deal, DealTerms, PackageMods, PackageData, PackagePrices, BondAction} from "./Types.sol";
import {PackageId} from "./PackageId.sol";
import {Settlement} from "./Settlement.sol";
import {IPassport} from "../packages/interfaces/IPassport.sol";
import {IReputation} from "../packages/interfaces/IReputation.sol";
import {IBondVault} from "../packages/interfaces/IBondVault.sol";
import {IPaymentProof} from "../packages/interfaces/IPaymentProof.sol";
import {ICourt} from "../packages/interfaces/ICourt.sol";

/// @title Packages
/// @notice The kernel's package edge, as an external library (DELEGATECALL from `Escrow`).
/// @dev Resolution binds signed ids to live module policy (TRUST-03) and copies the prices they name (`PackagePrices`,
///      Anexo R 2026-10-06); engagement identifies, admits and reserves; terminals invoice from that copy and run
///      post-terminal work. After activation the kernel never asks a package for its prices: a package may change
///      them for the deals to come, never for a live one. Everything a terminal calls on a module is `try`: a package
///      can lose its fee or its lock, never hold the principal hostage. Lives outside `Escrow` for bytecode headroom.
library Packages {
    using SafeERC20 for IERC20;

    /// @dev Which of the four fee moments (§E.3.14.6) a charge is. There is no fifth.
    enum FeeKind {
        Activation,
        Contest,
        Completion,
        Proof
    }

    /// @dev Every fee the kernel charges, as it charges it — so an indexer never has to deduce a fee from a
    ///      payout, which in a deadlock would read the burn as one.
    event FeeCharged(bytes32 indexed dealId, FeeKind kind, address indexed recipient, uint256 amount);

    uint8 internal constant PASSPORT = 1;
    uint8 internal constant REP = 2;
    uint8 internal constant BONDS = 4;
    uint8 internal constant ZK = 8;
    uint8 internal constant ARB = 16;

    /// Post-terminal package calls, as bits of `Deal.postPending`. Each is cleared only when its own call
    /// succeeds, which is what makes `Escrow.retryPostTerminal` idempotent.
    uint8 internal constant POST_NOTIFY_H = 0x01;
    uint8 internal constant POST_NOTIFY_P = 0x02;
    uint8 internal constant POST_BOND_A = 0x04;
    uint8 internal constant POST_BOND_B = 0x08;

    /// @dev A bond disposal TRUST-03 fails open on: the vault stopped answering or drifted off its signed
    ///      id, so the bit is cleared like a success and the lock stays in the vault permanently. It clears
    ///      exactly like a success, which is precisely why it needs its own announcement: `postPending`
    ///      reaching zero cannot tell the two apart, and one of them is real value nobody gets back.
    event BondDisposalAbandoned(bytes32 indexed dealId, address indexed vault);

    error UnknownPackage();
    error IncompatiblePackages();
    error PackageRequired();
    error PeerMismatch();
    error SameSubject();
    error FiatCommitRequired();

    // --- activation ----------------------------------------------------------------------------------

    /// @dev Every module the relayer names must hash to a signed id, and every signed id must be matched.
    ///      `PAYMENT_PROOF` proves a payment against the signed fiat leg, so it cannot run without one.
    ///      The prices each id hashes are returned as the deal's copy: what the kernel charges from here on.
    function resolve(bytes32[] memory ids, bytes32 fiatCommit, PackageMods memory mods)
        public
        view
        returns (uint8 pkgs, PackagePrices memory p)
    {
        uint256 matched;
        if (mods.passport != address(0)) {
            _requireNamed(ids, PackageId.passport(mods.passport));
            pkgs |= PASSPORT;
            matched++;
        }
        if (mods.reputation != address(0)) {
            IReputation r = IReputation(mods.reputation);
            if (address(r.passport()) != mods.passport) revert PeerMismatch();
            p.repFeeTo = r.feeRecipient();
            uint256 activation = r.activationBps();
            uint256 completion = r.completionBps();
            p.repContestBps = r.contestBps();
            p.repContestFloor = r.contestFloor();
            _requireNamed(
                ids,
                PackageId.reputation(
                    mods.reputation, p.repFeeTo, activation, completion, p.repContestBps, p.repContestFloor
                )
            );
            p.repActivationBps = _bps(activation);
            p.repCompletionBps = _bps(completion);
            pkgs |= REP;
            matched++;
        }
        if (mods.bonds != address(0)) {
            IBondVault vault = IBondVault(mods.bonds);
            if (address(vault.passport()) != mods.passport) revert PeerMismatch();
            _requireNamed(ids, PackageId.bonds(mods.bonds, vault.sink()));
            pkgs |= BONDS;
            matched++;
        }
        if (mods.zk != address(0)) {
            IPaymentProof z = IPaymentProof(mods.zk);
            p.zkFee = z.verifyFee();
            p.zkFeeTo = z.feeRecipient();
            _requireNamed(ids, PackageId.zk(address(z), address(z.verifier()), p.zkFeeTo, p.zkFee));
            pkgs |= ZK;
            matched++;
        }
        if (mods.court != address(0)) {
            ICourt c = ICourt(mods.court);
            (address partner, uint256 key) = c.packageBinding();
            p.courtContestFee = c.contestFee();
            p.courtFeeTo = c.feeRecipient();
            uint256 activation = c.activationBps();
            uint256 bondShare = c.bondShareBps();
            _requireNamed(
                ids,
                PackageId.arbitration(mods.court, partner, key, p.courtContestFee, p.courtFeeTo, activation, bondShare)
            );
            p.courtActivationBps = _bps(activation);
            p.courtBondShareBps = _bps(bondShare);
            pkgs |= ARB;
            matched++;
        }
        if (matched != ids.length) revert UnknownPackage();
        if ((pkgs & (ZK | ARB)) == (ZK | ARB)) revert IncompatiblePackages();
        if ((pkgs & ZK) != 0 && fiatCommit == bytes32(0)) revert FiatCommitRequired();
        if ((pkgs & REP) != 0 && (pkgs & PASSPORT) == 0) revert PackageRequired();
        if ((pkgs & BONDS) != 0 && (pkgs & (PASSPORT | REP)) != (PASSPORT | REP)) revert PackageRequired();
    }

    /// @dev Identify, admit (cap), pull the activation fee from the Holder, reserve both locks.
    ///      Runs in the kernel's context: pulls land on the escrow, then move to the fee recipient.
    ///      Each hook about a side receives that side's opaque package data (Anexo R, 2026-09-29).
    ///      Every fee is the copy `resolve` validated, never a re-read: `admit` and `bind` are not `view`, and a module
    ///      that answered one policy while it was checked cannot be paid by another.
    function engage(
        DealTerms memory t,
        uint8 pkgs,
        bytes32 dealId,
        PackageMods memory mods,
        PackageData memory data,
        PackagePrices memory p
    ) public returns (bytes32 subjectH, bytes32 subjectP) {
        if ((pkgs & PASSPORT) != 0) {
            subjectH = IPassport(mods.passport).identify(t.holder, t.controller, dealId, data.holder);
            subjectP = IPassport(mods.passport).identify(t.provider, t.provider, dealId, data.provider);
            // Two wallets, ONE account: the cheapest reputation farm there is, and until now nothing
            // stopped it. In the private layer `dealSubject = Poseidon(sk_id, dealId)` is deterministic,
            // so one account on both sides of one deal produces the SAME subject — visible here even
            // though the account behind it is not. Two DIFFERENT accounts of the same human stay
            // undetectable by construction; that is what the counterparty set prices instead (§E.3.14.7).
            if (subjectH == subjectP) revert SameSubject();
        }
        if ((pkgs & REP) != 0) {
            IReputation r = IReputation(mods.reputation);
            address v = (pkgs & BONDS) != 0 ? mods.bonds : address(0);
            r.admit(t.holder, dealId, t.token, t.principal, v, data.holder);
            r.admit(t.provider, dealId, t.token, t.principal, v, data.provider);
            uint256 fee = share(t.principal, p.repActivationBps);
            if (fee != 0) {
                Settlement.pullExact(t.token, t.holder, fee);
                IERC20(t.token).safeTransfer(p.repFeeTo, fee);
                emit FeeCharged(dealId, FeeKind.Activation, p.repFeeTo, fee);
            }
        }
        if ((pkgs & BONDS) != 0) {
            IBondVault vault = IBondVault(mods.bonds);
            vault.reserve(subjectH, t.token, dealId, t.principal, data.holder);
            vault.reserve(subjectP, t.token, dealId, t.principal, data.provider);
        }
        if ((pkgs & ARB) != 0) _engageCourt(t, dealId, ICourt(mods.court), data, p.courtActivationBps);
    }

    /// @dev The court learns its deal before the principal is in custody (Anexo R, 2026-09-28: the panel is fixed
    ///      during the negotiation). Its availability share, as signed, is pulled from the Holder and handed to the
    ///      court, which holds it until the deal ends.
    function _engageCourt(DealTerms memory t, bytes32 dealId, ICourt c, PackageData memory data, uint256 bps) private {
        uint256 fee = share(t.principal, bps);
        if (fee != 0) {
            Settlement.pullExact(t.token, t.holder, fee);
            IERC20(t.token).safeTransfer(address(c), fee);
            emit FeeCharged(dealId, FeeKind.Activation, address(c), fee);
        }
        c.bind(dealId, t, fee, data.court, data.holder, data.provider);
    }

    // --- live edges -----------------------------------------------------------------------------------

    /// @dev The ZK module of this deal and the proof price it was activated under.
    function zk(Deal storage d) public view returns (IPaymentProof z, uint256 fee, address to) {
        return (IPaymentProof(d.mods.zk), d.prices.zkFee, d.prices.zkFeeTo);
    }

    /// @dev The court of this deal. It was bound at activation; what it charges is the deal's copy.
    function court(Deal storage d) public view returns (ICourt) {
        return ICourt(d.mods.court);
    }

    /// @dev Whether the deal's court can still be escalated to. One whose getter reverts and one that says no both
    ///      read as unavailable: neither is a court the Controller could have used, so neither may turn a dispute
    ///      timeout into an abandonment.
    function courtAvailable(Deal storage d, bytes32 dealId) public view returns (bool) {
        try ICourt(d.mods.court).available(dealId) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @dev Where the court's share of the bonds goes, and how big it is, as signed: `(0, 0)` without a court or
    ///      with a zero share.
    function _courtCut(Deal storage d) private view returns (address to, uint256 bps) {
        if ((d.pkgs & ARB) == 0) return (address(0), 0);
        bps = d.prices.courtBondShareBps;
        if (bps == 0) return (address(0), 0);
        return (d.mods.court, bps);
    }

    /// @dev Contest-open invoice of the ARBITRATION package, as signed: `(0, 0)` without a court.
    function courtContestInvoice(Deal storage d) public view returns (uint256 fee, address to) {
        if ((d.pkgs & ARB) == 0) return (0, address(0));
        return (d.prices.courtContestFee, d.prices.courtFeeTo);
    }

    // --- terminals --------------------------------------------------------------------------------------

    /// @dev Completion invoice of this deal, as signed: `(0, 0)` without reputation.
    function completionInvoice(Deal storage d) public view returns (uint256 fee, address to) {
        if ((d.pkgs & REP) == 0) return (0, address(0));
        return (share(d.terms.principal, d.prices.repCompletionBps), d.prices.repFeeTo);
    }

    /// @dev A fee policy's share of the principal (Anexo R, 2026-09-28): `bps` of it, rounded down. A policy
    ///      of 100% or more is the whole principal — which `_invoice` then skips as a fee that does not fit —
    ///      so a module that declares an absurd share can neither overflow the arithmetic nor block a terminal
    ///      (KERNEL-04).
    function share(uint256 principal, uint256 bps) public pure returns (uint256) {
        if (bps >= 10_000) return principal;
        return principal * bps / 10_000;
    }

    /// @dev 1% when `bps == 100`. Zero bps is a flat floor (free if the floor is also 0).
    function contestDue(uint256 principal, uint256 bps, uint256 floor_) public pure returns (uint256) {
        if (bps == 0) return floor_;
        uint256 pct = principal * bps / 10_000;
        return pct < floor_ ? floor_ : pct;
    }

    /// @dev Contest-open invoice, as signed: `(0, 0)` without reputation. A healthy official module always charges,
    ///      which is what makes opening a fight cost something.
    function contestInvoice(Deal storage d) public view returns (uint256 fee, address to) {
        if ((d.pkgs & REP) == 0) return (0, address(0));
        return (contestDue(d.terms.principal, d.prices.repContestBps, d.prices.repContestFloor), d.prices.repFeeTo);
    }

    /// @dev Pull the contest-open fee from `payer` (the opener) once. Shared by `openDisputed` and
    ///      `openCourt` from `FIAT_SENT` so entering the fight cannot be charged twice. Fail-closed:
    ///      a short allowance reverts and the deal stays where it was. The fee is pulled, then
    ///      CREDITED to its recipient, then pushed if the token lets it: a recipient the token refuses (a
    ///      blacklist, a pause) must never block the Holder's only defence.
    function chargeContest(bytes32 dealId, Deal storage d, Settlement.Store storage payables, address payer) public {
        if (d.contestPaid) return;
        // Each selected package invoices its own contest (PROTOCOLO.md §E.3.14.6). A deal with a
        // tribunal costs something to fight in even without a reputation package -- otherwise
        // freezing is free for the only party who can freeze.
        (uint256 repFee, address repTo) = contestInvoice(d);
        (uint256 courtFee, address courtTo) = courtContestInvoice(d);
        d.contestPaid = true;
        _pullFee(dealId, payables, d.terms.token, payer, repFee, repTo);
        _pullFee(dealId, payables, d.terms.token, payer, courtFee, courtTo);
    }

    function _pullFee(
        bytes32 dealId,
        Settlement.Store storage payables,
        address token,
        address payer,
        uint256 fee,
        address to
    ) private {
        if (fee == 0) return;
        Settlement.pullExact(token, payer, fee);
        Settlement.creditThenTryPush(payables, token, to, fee);
        emit FeeCharged(dealId, FeeKind.Contest, to, fee);
    }

    // --- post-terminal work -----------------------------------------------------------------------------------

    /// @dev Which post-terminal calls this deal owes, from its bound kinds and the terminal's bond action.
    ///      `Unlock` is one call per subject; burn, slash and share take both subjects in a single call.
    function postTerminalOwed(Deal storage d, BondAction bond) public view returns (uint8 owed) {
        if ((d.pkgs & REP) != 0) owed = POST_NOTIFY_H | POST_NOTIFY_P;
        if ((d.pkgs & BONDS) != 0) owed |= bond == BondAction.Unlock ? POST_BOND_A | POST_BOND_B : POST_BOND_A;
    }

    /// @dev Attempt the post-terminal calls still set in `pending` and return the bits that remain. One
    ///      implementation serves both the first attempt from `_close` and every retry from
    ///      `Escrow.retryPostTerminal`, so the two cannot drift apart.
    ///
    ///      Every call is `try`, because a package can lose its fee or its lock but never hold the principal
    ///      hostage (KERNEL-04). A bit is cleared only when its call succeeds, so a retry can never apply a
    ///      reputation delta twice or dispose the same lock twice.
    ///
    ///      A bond call is also cleared when the vault is unreadable or has drifted off its signed id:
    ///      TRUST-03 makes that a permanent fail-open with the lock left in the vault, so keeping the bit set
    ///      would leave `postPending` unable to ever reach zero. Reputation has no such gate -- a
    ///      notification is not a charge, and its fees come from the deal's copy anyway --
    ///      so its bits stay pending until the module answers. A module that never comes back leaves them set,
    ///      and `retryPostTerminal` stays callable as a no-op; that is deliberate, because silently dropping
    ///      the notification would hide a subject's capacity leak.
    function runPostTerminal(
        Deal storage d,
        bytes32 dealId,
        uint8 closeH,
        uint8 closeP,
        uint8 bondAction,
        uint8 pending
    ) public returns (uint8 left) {
        left = pending;
        DealTerms storage t = d.terms;

        if ((left & (POST_NOTIFY_H | POST_NOTIFY_P)) != 0 && (d.pkgs & REP) != 0) {
            IReputation r = IReputation(d.mods.reputation);
            if ((left & POST_NOTIFY_H) != 0) {
                try r.notifyTerminal(d.subjectH, d.subjectP, t.token, t.principal, IReputation.Close(closeH)) {
                    left &= ~POST_NOTIFY_H;
                } catch {}
            }
            if ((left & POST_NOTIFY_P) != 0) {
                try r.notifyTerminal(d.subjectP, d.subjectH, t.token, t.principal, IReputation.Close(closeP)) {
                    left &= ~POST_NOTIFY_P;
                } catch {}
            }
        }

        if ((left & (POST_BOND_A | POST_BOND_B)) != 0 && (d.pkgs & BONDS) != 0) {
            IBondVault vault = IBondVault(d.mods.bonds);
            address sink;
            bool readable = true;
            try vault.sink() returns (address s) {
                sink = s;
            } catch {
                readable = false;
            }
            if (!readable || !named(d, PackageId.bonds(address(vault), sink))) {
                left &= ~(POST_BOND_A | POST_BOND_B);
                emit BondDisposalAbandoned(dealId, address(vault));
                return left;
            }
            BondAction bond = BondAction(bondAction);
            if (bond == BondAction.Unlock) {
                if ((left & POST_BOND_A) != 0) {
                    try vault.unlock(d.subjectH, t.token, dealId) {
                        left &= ~POST_BOND_A;
                    } catch {}
                }
                if ((left & POST_BOND_B) != 0) {
                    try vault.unlock(d.subjectP, t.token, dealId) {
                        left &= ~POST_BOND_B;
                    } catch {}
                }
            } else if ((left & POST_BOND_A) != 0) {
                bool done;
                (address feeTo, uint256 feeBps) = _courtCut(d);
                if (bond == BondAction.Burn) {
                    try vault.burn(d.subjectH, d.subjectP, t.token, dealId) {
                        done = true;
                    } catch {}
                } else if (bond == BondAction.Shared) {
                    try vault.share(d.subjectH, d.subjectP, t.token, dealId, feeTo, feeBps) {
                        done = true;
                    } catch {}
                } else if (bond == BondAction.HolderWins) {
                    try vault.slash(d.subjectP, d.subjectH, t.token, dealId, t.holder, feeTo, feeBps) {
                        done = true;
                    } catch {}
                } else {
                    try vault.slash(d.subjectH, d.subjectP, t.token, dealId, t.provider, feeTo, feeBps) {
                        done = true;
                    } catch {}
                }
                if (done) left &= ~POST_BOND_A;
            }
        }
    }

    // --- helpers --------------------------------------------------------------------------------------------

    function named(Deal storage d, bytes32 id) public view returns (bool) {
        bytes32[] storage ids = d.terms.packageIds;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    function _requireNamed(bytes32[] memory ids, bytes32 id) private pure {
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return;
        }
        revert UnknownPackage();
    }

    /// @dev A share as the deal keeps it: anything at or above 100% is 100%, which is how `share` and the court cut
    ///      read it anyway.
    function _bps(uint256 bps) private pure returns (uint16) {
        return bps >= 10_000 ? 10_000 : uint16(bps);
    }
}
