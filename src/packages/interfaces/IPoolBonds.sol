// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev The public bond accounts of official pools (Anexo R, 2026-10-05). A pool is a peer: it carries a bond like
///      any account, but a pool is a business with a public record, so its bond is public too — no notes, no proofs.
///      It belongs to the pool: anyone may fund it, only the pool takes it back.
interface IPoolBonds {
    /// @notice Pulls `amount` of `token` from the caller into `pool`'s free bond. `pool` must be official.
    function depositPool(address pool, address token, uint256 amount) external;
    /// @notice Sends `amount` of the caller's free bond back to the caller, which must be an official pool.
    function withdrawPool(address token, uint256 amount) external;
    /// @notice The pool's bond: free plus locked in live deals.
    function poolBondOf(address pool, address token) external view returns (uint256);
    /// @notice The part of the pool's bond no live deal holds.
    function poolFreeOf(address pool, address token) external view returns (uint256);
}
