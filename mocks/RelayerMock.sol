// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods,
    PackageData
} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";

/// @dev Stand-in for whoever assembles a private activation (PROTOCOLO.md §E.3.15.4): it builds each side's
///      `prepare_side` inputs out of the deal's terms and the side's commitments, and hands them to the
///      kernel as that side's opaque package data (Anexo R, 2026-09-29). There is nothing to compose any
///      more: the proofs travel inside `activate`, so the activation is atomic by construction. Pass the
///      zero vault for a PASSPORT+REPUTATION deal; the bond pieces of the sides are then ignored. NOT the
///      real relayer: no fees, no liveness, no censorship resistance.
contract RelayerMock {
    /// @dev One deal side's pieces of the activation bundle.
    struct Side {
        address wallet;
        bytes32 dealSubject;
        bytes32 newLeaf;
        bytes32 nullRep;
        /// @dev One proof for the whole side (§E.3.15.4), verified once by the private passport.
        bytes sideProof;
        // Bond pieces (F3): read only when the deal selects BONDS.
        bytes32 lockCommit;
        bytes32 changeNote;
        bytes32 nullBond;
        /// @dev An account without a Passport (2026-10-01). Named for the exception so a side left at its
        ///      default is the verified one every existing flow means.
        bool open;
    }

    /// @dev One side's public inputs, assembled from the deal's own terms and the side's commitments.
    ///      Everything here is either public already or something the side is about to have written
    ///      for it, which is why the relayer can compose it without knowing a single secret.
    function _inputs(
        Side calldata side,
        bytes32 dealId,
        HolderAuthorization calldata ha,
        bytes32 pairTag,
        bytes32 repRoot,
        bytes32 bondRoot
    ) internal pure returns (IBundleVerifier.BundleInputs memory) {
        bool bonded = bondRoot != bytes32(0);
        return IBundleVerifier.BundleInputs({
            dealSubject: side.dealSubject,
            dealId: dealId,
            token: ha.terms.token,
            principal: ha.terms.principal,
            repRoot: repRoot,
            newLeaf: side.newLeaf,
            nullRep: side.nullRep,
            pairTag: pairTag,
            lockCommit: bonded ? side.lockCommit : bytes32(0),
            lockAmount: bonded ? (ha.terms.principal + 9) / 10 : 0,
            changeNote: bonded ? side.changeNote : bytes32(0),
            nullBond: bonded ? side.nullBond : bytes32(0),
            bondRoot: bondRoot,
            registryId: bytes32(0),
            hintS: bytes32(0),
            hintK: bytes32(0),
            arbiters: [bytes32(0), bytes32(0), bytes32(0)],
            verified: !side.open
        });
    }

    function activatePrivate(
        Escrow escrow,
        PrivatePassport,
        PrivateReputation reputation,
        PrivateBondVault vault,
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods calldata mods,
        bytes32 dealId,
        Side calldata h,
        Side calldata p,
        /// @dev The §E.3.14.7 pair tag: one value for the deal, proven by both sides and matched by the
        ///      module when it admits the second of them.
        bytes32 pairTag,
        IBundleVerifier
    ) external returns (bytes32 id) {
        bool bonded = address(vault) != address(0);
        // Both sides prove against the SAME root: nothing is inserted between them, so both proofs can
        // be produced in parallel, off-chain, before anyone sends a transaction.
        bytes32 repRoot = reputation.accountTree().root();
        bytes32 bondRoot = bonded ? vault.bondRoot() : bytes32(0);
        PackageData memory data = PackageData({
            holder: abi.encode(_inputs(h, dealId, ha, pairTag, repRoot, bondRoot), h.sideProof),
            provider: abi.encode(_inputs(p, dealId, ha, pairTag, repRoot, bondRoot), p.sideProof),
            court: ""
        });
        return escrow.activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods, data);
    }
}
