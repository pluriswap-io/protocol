// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

/// @title Delta parity (§E.3.15.5, V3)
/// @dev The terminal-delta table pinned across its three implementations: the in-circuit
///      twin (`claim`, proven by the claim proof and its every-kind test), the JS twin
///      (`circuits/js/vectors.ts`, the generator that emits the committed rows) and this
///      pure mirror — all against the committed rows of test/fixtures/vectors.json
///      (`deltas` section). The rows all start from the prepare sample's current leaf (the
///      principal in flight), so the table reads as: what does each Close move, and by how
///      much — the atomicity §E.3.15.5 pins (count/volume/penalty/inFlight move together or
///      nothing does; not claiming the penalty means never releasing the inFlight).
contract DeltaParityTest is Test {
    string internal vectors;

    function setUp() public {
        vectors = vm.readFile("test/fixtures/vectors.json");
    }

    /// @dev The §E.3.15.5 delta's count/volume/penalty columns: Peaceful completes the deal
    ///      (+1 count, +principal volume), Silent and ArbWin move neither, Stalemate
    ///      punishes +5, ArbLoss +15, Deadlock +10 (Anexo R, 2026-09-24), NoShow +5 (2026-09-28). The inFlight column is the caller's — it is the
    ///      satSub twin (inFlight − principal, saturating), shared by every kind.
    function _delta(uint8 kind, uint256 count, uint256 volume, uint256 penalty, uint256 principal)
        internal
        pure
        returns (uint256 newCount, uint256 newVolume, uint256 newPenalty)
    {
        newCount = kind == 0 ? count + 1 : count;
        newVolume = kind == 0 ? volume + principal : volume;
        newPenalty = penalty + (kind == 2 ? 5 : 0) + (kind == 4 ? 15 : 0) + (kind == 5 ? 10 : 0) + (kind == 6 ? 5 : 0);
    }

    function test_deltaRows_matchTheTable() public view {
        // The rows are an array of objects: read them per row (indexed paths), not per
        // column — this forge cannot lift a whole column out of an array of objects, and
        // has no working array-length cheatcode, so the generator also names the count.
        uint256 rows = vm.parseJsonUint(vectors, ".deltas_rows");
        assertEq(rows, 7, "one row per Close kind, NoShow included");
        for (uint256 i = 0; i < rows; i++) {
            string memory row = string.concat(".deltas[", vm.toString(i), "]");
            uint8 kind = uint8(vm.parseJsonUint(vectors, string.concat(row, ".kind")));
            uint256 count = vm.parseJsonUint(vectors, string.concat(row, ".count"));
            uint256 volume = vm.parseJsonUint(vectors, string.concat(row, ".volume"));
            uint256 penalty = vm.parseJsonUint(vectors, string.concat(row, ".penalty"));
            uint256 inFlight = vm.parseJsonUint(vectors, string.concat(row, ".in_flight"));
            uint256 principal = vm.parseJsonUint(vectors, string.concat(row, ".principal"));

            (uint256 nc, uint256 nv, uint256 np) = _delta(kind, count, volume, penalty, principal);
            // §E.3.15.5: every kind releases the principal from flight — the satSub twin.
            uint256 ni = inFlight > principal ? inFlight - principal : 0;

            assertEq(nc, vm.parseJsonUint(vectors, string.concat(row, ".new_count")), "new count");
            assertEq(nv, vm.parseJsonUint(vectors, string.concat(row, ".new_volume")), "new volume");
            assertEq(np, vm.parseJsonUint(vectors, string.concat(row, ".new_penalty")), "new penalty");
            assertEq(ni, vm.parseJsonUint(vectors, string.concat(row, ".new_in_flight")), "new inFlight");
        }
    }

    function test_theSevenCloses() public pure {
        // The table by hand, as §E.3.15.5 reads it — over the sample leaf (count 0, the
        // principal in flight): each kind's exact move, and the atomicity's edge (the
        // penalty applies WITH the release, never instead of it).
        (uint256 nc, uint256 nv, uint256 np) = _delta(0, 0, 0, 0, 100_000_000);
        assertEq(nc, 1, "Peaceful counts");
        assertEq(nv, 100_000_000, "Peaceful volumes the principal");
        assertEq(np, 0, "Peaceful does not punish");
        (nc, nv, np) = _delta(1, 0, 0, 0, 100_000_000);
        assertEq(nc, 0, "Silent does not count");
        assertEq(nv, 0, "Silent does not volume");
        assertEq(np, 0, "Silent does not punish");
        (nc, nv, np) = _delta(2, 0, 0, 0, 100_000_000);
        assertEq(nc, 0, "Stalemate does not count");
        assertEq(nv, 0, "Stalemate does not volume");
        assertEq(np, 5, "Stalemate punishes 5");
        (nc, nv, np) = _delta(3, 0, 0, 0, 100_000_000);
        assertEq(np, 0, "ArbWin does not punish");
        (nc, nv, np) = _delta(4, 0, 0, 0, 100_000_000);
        assertEq(np, 15, "ArbLoss punishes 15");
        assertEq(nc, 0, "ArbLoss does not count");
        (nc, nv, np) = _delta(5, 0, 0, 0, 100_000_000);
        assertEq(np, 10, "Deadlock punishes 10: between a tribunal's refusal and a proven loss");
        assertEq(nc, 0, "Deadlock does not count: no trade closed");
        assertEq(nv, 0, "Deadlock does not volume");
        (nc, nv, np) = _delta(6, 0, 0, 0, 100_000_000);
        assertEq(np, 5, "NoShow punishes 5: one bad clock");
        assertEq(nc, 0, "NoShow does not count: nothing was traded");
        assertEq(nv, 0, "NoShow does not volume");
    }
}
