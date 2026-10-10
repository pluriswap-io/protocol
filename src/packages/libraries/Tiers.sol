// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Tiers
/// @notice The ladder of PROTOCOLO.md §E.3.14.7 in the clear: the twin of `circuits/.../tiers.nr`, which proves the same
///         table in-circuit for a private account. A pool climbs it in the clear (Anexo R, 2026-10-05): a pool is a
///         peer, under the same rules as anyone, and its record is public.
library Tiers {
    /// @dev `satSub(count + volume / unit, penalty)`, `unit = 250 * 10^decimals`: one lot is a full-cap T1 deal.
    function score(uint256 count, uint256 volume, uint256 penalty, uint256 unit) internal pure returns (uint256) {
        uint256 raw = count + volume / unit;
        return raw > penalty ? raw - penalty : 0;
    }

    /// @dev The concurrent cap a score buys, in raw units (`scale = 10^decimals`). T5's unbounded column is the bond
    ///      one: without a lock behind it the ladder tops out at 5.000.
    function cap(uint256 sc, bool withBond, uint256 scale) internal pure returns (uint256) {
        if (sc >= 100 && withBond) return type(uint256).max;
        uint256 tokens;
        if (sc >= 100) tokens = 5000;
        else if (sc >= 50) tokens = withBond ? 5000 : 2000;
        else if (sc >= 25) tokens = withBond ? 1500 : 1000;
        else if (sc >= 10) tokens = withBond ? 700 : 500;
        else tokens = withBond ? 400 : 250;
        return tokens * scale;
    }
}
