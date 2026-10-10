// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PinnedAnchors} from "../src/packages/adapters/PinnedAnchors.sol";

/// @dev Exposes the window lookup a rail adapter runs before handing bounds to its circuit.
contract AnchorsHarness is PinnedAnchors {
    constructor(Anchor[] memory anchors_) PinnedAnchors(anchors_) {}

    function window(bytes32 keyHash, uint64 notBefore) external view returns (bool ok, uint64 lo, uint64 hi) {
        return _window(keyHash, notBefore);
    }
}

/// @dev The key rotation policy of §E.3.12.1 (Anexo R, 2026-09-24), as the base every rail adapter shares:
///      trust anchors fixed at deploy, each with a bounded window, no setter, no admin. Rotating is
///      publishing another adapter — another `packageId` — never editing this one.
contract PinnedAnchorsTest is Test {
    bytes32 internal constant KEY_A = keccak256("dkim-2026a");
    bytes32 internal constant KEY_B = keccak256("dkim-2026b");
    uint64 internal constant T0 = 1_800_000_000;

    function _one(bytes32 key, uint64 from, uint64 until) internal pure returns (PinnedAnchors.Anchor[] memory a) {
        a = new PinnedAnchors.Anchor[](1);
        a[0] = PinnedAnchors.Anchor({keyHash: key, validFrom: from, validUntil: until});
    }

    /// The current key and its pre-published successor, overlapping — the planned rotation.
    function _pair() internal pure returns (PinnedAnchors.Anchor[] memory a) {
        a = new PinnedAnchors.Anchor[](2);
        a[0] = PinnedAnchors.Anchor({keyHash: KEY_A, validFrom: T0, validUntil: T0 + 180 days});
        a[1] = PinnedAnchors.Anchor({keyHash: KEY_B, validFrom: T0 + 150 days, validUntil: T0 + 330 days});
    }

    // --- construction: what an adapter may pin -----------------------------------------------------------

    function test_sunsetIsTheLastWindowEnd() public {
        AnchorsHarness h = new AnchorsHarness(_pair());
        assertEq(h.sunset(), T0 + 330 days);
        assertEq(h.anchors().length, 2);
    }

    function test_rejectsNoAnchors() public {
        vm.expectRevert(PinnedAnchors.NoAnchors.selector);
        new AnchorsHarness(new PinnedAnchors.Anchor[](0));
    }

    function test_rejectsTooManyAnchors() public {
        PinnedAnchors.Anchor[] memory a = new PinnedAnchors.Anchor[](9);
        for (uint256 i = 0; i < 9; i++) {
            a[i] = PinnedAnchors.Anchor({keyHash: bytes32(i + 1), validFrom: T0, validUntil: T0 + 1 days});
        }
        vm.expectRevert(PinnedAnchors.TooManyAnchors.selector);
        new AnchorsHarness(a);
    }

    function test_rejectsZeroKey() public {
        vm.expectRevert(PinnedAnchors.BadAnchor.selector);
        new AnchorsHarness(_one(bytes32(0), T0, T0 + 1 days));
    }

    function test_rejectsEmptyOrInvertedWindow() public {
        vm.expectRevert(PinnedAnchors.BadAnchor.selector);
        new AnchorsHarness(_one(KEY_A, T0, T0));
        vm.expectRevert(PinnedAnchors.BadAnchor.selector);
        new AnchorsHarness(_one(KEY_A, T0 + 1, T0));
    }

    /// The ceiling is what bounds a leaked key without anyone having to act: nothing can pin a key for
    /// longer than a rail should keep one, so even an abandoned package stops trusting it.
    function test_rejectsWindowLongerThanTheCeiling() public {
        vm.expectRevert(PinnedAnchors.BadAnchor.selector);
        new AnchorsHarness(_one(KEY_A, T0, T0 + 400 days + 1));
        new AnchorsHarness(_one(KEY_A, T0, T0 + 400 days)); // the ceiling itself is allowed
    }

    function test_rejectsTheSameKeyTwice() public {
        PinnedAnchors.Anchor[] memory a = new PinnedAnchors.Anchor[](2);
        a[0] = PinnedAnchors.Anchor({keyHash: KEY_A, validFrom: T0, validUntil: T0 + 10 days});
        a[1] = PinnedAnchors.Anchor({keyHash: KEY_A, validFrom: T0 + 20 days, validUntil: T0 + 30 days});
        vm.expectRevert(PinnedAnchors.BadAnchor.selector);
        new AnchorsHarness(a);
    }

    // --- the window: what a proof may use -----------------------------------------------------------------

    /// A deal activated inside a key's window: the circuit proves the payment falls in
    /// [max(activation, validFrom), validUntil]. The payment time itself is never published.
    function test_window_boundsThePayment() public {
        AnchorsHarness h = new AnchorsHarness(_pair());
        (bool ok, uint64 lo, uint64 hi) = h.window(KEY_A, T0 + 10 days);
        assertTrue(ok);
        assertEq(lo, T0 + 10 days);
        assertEq(hi, T0 + 180 days);
    }

    /// A deal activated BEFORE the successor goes live may still be paid under it: the lower bound
    /// moves up to the key's own start, so nothing signed before the key existed can count.
    function test_window_successorStartsWhereItStarts() public {
        AnchorsHarness h = new AnchorsHarness(_pair());
        (bool ok, uint64 lo, uint64 hi) = h.window(KEY_B, T0 + 10 days);
        assertTrue(ok);
        assertEq(lo, T0 + 150 days);
        assertEq(hi, T0 + 330 days);
    }

    function test_window_unknownKey_fails() public {
        AnchorsHarness h = new AnchorsHarness(_pair());
        (bool ok,,) = h.window(keccak256("a key nobody signed"), T0 + 10 days);
        assertFalse(ok);
    }

    /// A deal activated after a key's window closed can never be paid under that key.
    function test_window_expiredKey_fails() public {
        AnchorsHarness h = new AnchorsHarness(_pair());
        (bool ok,,) = h.window(KEY_A, T0 + 181 days);
        assertFalse(ok);
        (ok,,) = h.window(KEY_B, T0 + 181 days);
        assertTrue(ok, "the successor still covers it");
    }
}
