// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `withdraw` circuit. The proof says: "I own the note behind `nullBond`
///      (a leaf of `bondRoot`, a note of `token` worth `noteAmount`); `noteAmount = amount +
///      changeAmount`; and `changeNote = Poseidon(sk_id, token, changeAmount, changeSalt)`, or
///      zero when `amount` consumes the note whole". `dest` is any address the owner names: the
///      proof replaces `passport.identify` (PROTOCOLO.md §E.3.15.6), so a withdraw never touches the
///      passport and never links the note to the wallet that funded the deposit.
interface IWithdrawVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyWithdraw(
        address token,
        address dest,
        uint256 amount,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 bondRoot,
        bytes calldata proof
    ) external view returns (bool);
}
