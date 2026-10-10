// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

/// @title Tier parity (§E.3.14.7, V2)
/// @dev The admission-tier table pinned across its four implementations: the on-chain
///      reputation (`Reputation.score` / `Reputation._capTokens`), the in-circuit twin
///      (`pluri_commitments::tiers`, proven by prepare_admit), the JS twin
///      (`circuits/js/lib/tiers.ts`, the generator's zero gate) and this pure mirror —
///      all against the committed rows of test/fixtures/vectors.json (`tiers` section).
///
///      score = satSub(count + volume / UNIT, penalty) with UNIT = 250 * 10^decimals;
///      caps: base 250/500/1000/2000/5000, bond 400/700/1500/5000/unbounded (only T5's bond
///      column is unbounded — unlimited exposure requires a live lock behind it).
contract TierParityTest is Test {
    string internal vectors;

    function setUp() public {
        vectors = vm.readFile("test/fixtures/vectors.json");
    }

    /// @dev The §E.3.14.7 score: truncated volume lots, saturating penalty subtraction —
    ///      the same arithmetic `Reputation.score` performs over its stats.
    function _score(uint256 count, uint256 volume, uint256 penalty, uint8 decimals) internal pure returns (uint256) {
        uint256 unit = 250 * 10 ** uint256(decimals);
        uint256 raw = count + volume / unit;
        return raw > penalty ? raw - penalty : 0;
    }

    /// @dev The §E.3.14.7 cap table — the same ladder `Reputation._capTokens` walks.
    function _capUnits(uint256 sc, bool withBond) internal pure returns (bool unbounded, uint256 cap) {
        if (sc >= 100) return withBond ? (true, 0) : (false, 5000);
        if (sc >= 50) return (false, withBond ? 5000 : 2000);
        if (sc >= 25) return (false, withBond ? 1500 : 1000);
        if (sc >= 10) return (false, withBond ? 700 : 500);
        return (false, withBond ? 400 : 250);
    }

    function test_tierRows_matchTheTable() public view {
        // The rows are an array of objects: read them per row (indexed paths), not per
        // column — this forge cannot lift a whole column out of an array of objects, and
        // has no working array-length cheatcode, so the generator also names the count.
        uint256 rows = vm.parseJsonUint(vectors, ".tiers_rows");
        for (uint256 i = 0; i < rows; i++) {
            string memory row = string.concat(".tiers[", vm.toString(i), "]");
            uint256 count = vm.parseJsonUint(vectors, string.concat(row, ".count"));
            uint256 volume = vm.parseJsonUint(vectors, string.concat(row, ".volume"));
            uint256 penalty = vm.parseJsonUint(vectors, string.concat(row, ".penalty"));
            uint8 decimals = uint8(vm.parseJsonUint(vectors, string.concat(row, ".decimals")));
            uint256 expScore = vm.parseJsonUint(vectors, string.concat(row, ".score"));
            uint256 capBase = vm.parseJsonUint(vectors, string.concat(row, ".cap_base"));
            uint256 capBond = vm.parseJsonUint(vectors, string.concat(row, ".cap_bond"));
            bool unboundedBase = vm.parseJsonBool(vectors, string.concat(row, ".unbounded_base"));
            bool unboundedBond = vm.parseJsonBool(vectors, string.concat(row, ".unbounded_bond"));

            uint256 sc = _score(count, volume, penalty, decimals);
            assertEq(sc, expScore, "score");
            (bool ub, uint256 units) = _capUnits(sc, false);
            assertTrue(ub == unboundedBase, "base unbounded");
            assertEq(ub ? 0 : units * 10 ** decimals, capBase, "base cap");
            (bool ubB, uint256 unitsB) = _capUnits(sc, true);
            assertTrue(ubB == unboundedBond, "bond unbounded");
            assertEq(ubB ? 0 : unitsB * 10 ** decimals, capBond, "bond cap");
        }
    }

    function test_theFiveTiers() public pure {
        // The ladder by hand, as §E.3.14.7 reads it — boundary-anchored on both sides.
        (bool ub0, uint256 t1) = _capUnits(0, false);
        (bool ub0b, uint256 t1b) = _capUnits(9, true);
        assertFalse(ub0);
        assertFalse(ub0b);
        assertEq(t1, 250, "T1 base");
        assertEq(t1b, 400, "T1 bond");
        (, uint256 t2) = _capUnits(10, false);
        assertEq(t2, 500, "T2 base");
        (, uint256 t3) = _capUnits(24, false);
        assertEq(t3, 500, "24 still T2");
        (, uint256 t3x) = _capUnits(25, false);
        assertEq(t3x, 1000, "T3 base");
        (, uint256 t4) = _capUnits(50, false);
        assertEq(t4, 2000, "T4 base");
        (, uint256 t4b) = _capUnits(50, true);
        assertEq(t4b, 5000, "T4 bond");
        (bool ub5, uint256 t5) = _capUnits(100, false);
        assertFalse(ub5, "T5 base is finite");
        assertEq(t5, 5000, "T5 base tops at T4's bond column");
        (bool ub5b,) = _capUnits(250, true);
        assertTrue(ub5b, "only T5's bond column is unbounded");
    }

    function test_satSub_andTruncation() public pure {
        // Penalty saturates at zero; volume lots truncate (a 249_999_999-unit remainder is
        // not a lot) — the two integer semantics the score is made of.
        assertEq(_score(5, 0, 7, 6), 0, "penalty saturates");
        assertEq(_score(0, 250_000_000, 0, 6), 1, "one lot");
        assertEq(_score(0, 250_000_001, 0, 6), 1, "remainder dropped");
        assertEq(_score(9, 2_249_999_999, 0, 6), 17, "count + lots");
    }
}
