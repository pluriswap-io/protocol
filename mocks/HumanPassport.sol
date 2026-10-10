// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackageId} from "../src/libraries/PackageId.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IGitcoinPassportDecoder} from "../src/packages/interfaces/IGitcoinPassportDecoder.sol";

/// @dev LAB STAND-IN since 2026-09-29 (Anexo R: one kind of deal, the private one). This was the public
///      package of the same name; it left `src/` and is no longer part of the product. It stays because the
///      kernel's behaviour suites and the anvil e2e need a concrete, wallet-keyed module to drive, and
///      `mocks/` is where such things live: never a production identity.
/// @title HumanPassport
/// @notice PASSPORT adapter over Human Passport (ex Gitcoin Passport) on-chain scores.
/// @dev The decoder scores **addresses**, not humans: the subject is the wallet itself, widened to bytes32.
///      Sybil resistance comes from Passport's stamp deduplication (a stamp counts for one address at a time),
///      so two wallets can only both be "human" by holding two disjoint sets of stamps.
///
///      Policy is immutable and therefore bound by `PackageId.passport(address(this))`: a different decoder or
///      threshold is a different adapter, a different id, a different signature.
///
///      `minScore == 0` defers to the decoder's own `isHuman` (threshold set by the Passport team, upgradeable).
///      `minScore > 0` pins a threshold in this adapter, 4 decimals, e.g. 200_000 = 20.0.
///
///      Any decoder revert (no attestation, expired attestation, paused proxy) is `NoPassport`: admission fails
///      closed and the kernel never burns a nonce. Live deals are unaffected because the kernel snapshots
///      subjects at activation and `notifyTerminal` never re-identifies (ADM-05).
contract HumanPassport is IPassport {
    IGitcoinPassportDecoder public immutable decoder;
    uint256 public immutable minScore;
    bytes32 public immutable packageId;

    error ZeroDecoder();

    constructor(IGitcoinPassportDecoder decoder_, uint256 minScore_) {
        if (address(decoder_) == address(0)) revert ZeroDecoder();
        decoder = decoder_;
        minScore = minScore_;
        packageId = PackageId.passport(address(this));
    }

    /// @inheritdoc IPassport
    function identify(address wallet, address, bytes32, bytes calldata) external view returns (bytes32 subject) {
        if (!isHuman(wallet)) revert NoPassport();
        return subjectOf(wallet);
    }

    /// @notice The subject a wallet maps to if it passes. Pure: UIs and vault depositors can derive it offline.
    function subjectOf(address wallet) public pure returns (bytes32) {
        return bytes32(uint256(uint160(wallet)));
    }

    /// @notice Humanity check under this adapter's policy. Never reverts; decoder failures read as `false`.
    function isHuman(address wallet) public view returns (bool) {
        if (minScore == 0) {
            try decoder.isHuman(wallet) returns (bool ok) {
                return ok;
            } catch {
                return false;
            }
        }
        try decoder.getScore(wallet) returns (uint256 s) {
            return s >= minScore;
        } catch {
            return false;
        }
    }

    /// @notice Current score, 4 decimals; `(0, false)` when the decoder has no live attestation.
    function score(address wallet) external view returns (uint256 value, bool live) {
        try decoder.getScore(wallet) returns (uint256 s) {
            return (s, true);
        } catch {
            return (0, false);
        }
    }
}
