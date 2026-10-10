// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Verifier of the `deposit` circuit. Fresh value only ever enters the notes world here, so
///      this is the one place a note must be pinned to the public amount: the proof says
///      "note = Poseidon(sk_id, token, amount, salt), and I know sk_id". Every later note creation
///      (a split's change note, a reabsorb's merge) is conservation-bounded inside its own circuit;
///      without this binding, a 10-token deposit could insert a note committing to a million.
interface IDepositVerifier {
    /// @notice MUST fail closed: a malformed proof reads as `false`, never as a revert-shaped pass.
    function verifyDeposit(address token, uint256 amount, bytes32 note, bytes calldata proof)
        external
        view
        returns (bool);
}
