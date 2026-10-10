// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kernel verb `identify`. Answers "is this wallet human under the adapter's policy?": returns the
///      subject that reputation, `inFlight` and bonds are keyed by, or reverts `NoPassport`. The official
///      adapter (`HumanPassport`) maps a passing wallet to itself; it does not identify the human behind it.
interface IPassport {
    error NoPassport();

    /// @dev `dealId` and `data` are the activation's: the opaque bytes the parties handed the kernel for this
    ///      side (Anexo R, 2026-09-29). A wallet-keyed adapter ignores both; the private one verifies the
    ///      side's proof out of `data` and answers the subject it names. Not `view` for that reason.
    ///      Each side is an ACCOUNT and an OPERATOR (Anexo R, 2026-10-05): `account` is the side's address in the
    ///      terms — the Holder or the Provider — and `operator` the one who acts for it — the Controller for the
    ///      Holder's side, the Provider itself for the Provider's. In a person they are the same and an adapter
    ///      may ignore `operator`; in a pool they are not, and the private adapter checks the operator's proof.
    function identify(address account, address operator, bytes32 dealId, bytes calldata data)
        external
        returns (bytes32 subject);
    function packageId() external view returns (bytes32);
}
