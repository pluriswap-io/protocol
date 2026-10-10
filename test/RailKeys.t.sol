// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PinnedAnchors} from "../src/packages/adapters/PinnedAnchors.sol";
import {RailKeys} from "../src/packages/adapters/RailKeys.sol";
import {IPaymentVerifier} from "../src/packages/interfaces/IPaymentVerifier.sol";
import {Mock1271} from "../mocks/Mock1271.sol";

/// @dev Exposes the key decision a rail adapter makes before handing bounds to its circuit.
contract RailKeysHarness is RailKeys {
    constructor(Anchor[] memory anchors_) RailKeys(anchors_) {}

    function keyAllowed(IPaymentVerifier.PaymentClaim memory claim, bytes32 keyHash, bytes memory approval)
        external
        view
        returns (bool ok, uint64 lo, uint64 hi)
    {
        return _keyAllowed(claim, keyHash, approval);
    }
}

/// @dev The key policy of §E.3.12.1 (Anexo R, 2026-09-24): pinned defaults, extended per deal by the one
///      party a false key could hurt. Two asymmetries carry the whole design, and each has tests here:
///        * the HOLDER can extend trust for their own deal, and cannot restrict it;
///        * nobody else — the Provider least of all — can produce that extension.
contract RailKeysTest is Test {
    bytes32 internal constant KEY_A = keccak256("dkim-2026a"); // pinned
    bytes32 internal constant KEY_C = keccak256("dkim-2026c"); // the bank's new key, pinned by nobody
    bytes32 internal constant DEAL = keccak256("deal");
    bytes32 internal constant FIAT = bytes32(uint256(7));
    uint64 internal constant T0 = 1_800_000_000;

    uint256 internal holderPk = 0xA11CE;
    uint256 internal providerPk = 0xB0B;
    address internal holder;

    RailKeysHarness internal rail;

    function setUp() public {
        holder = vm.addr(holderPk);
        PinnedAnchors.Anchor[] memory a = new PinnedAnchors.Anchor[](1);
        a[0] = PinnedAnchors.Anchor({keyHash: KEY_A, validFrom: T0, validUntil: T0 + 180 days});
        rail = new RailKeysHarness(a);
    }

    // --- the defaults need nobody ------------------------------------------------------------------------

    function test_pinnedKey_needsNoApproval() public view {
        (bool ok, uint64 lo, uint64 hi) = rail.keyAllowed(_claim(holder), KEY_A, "");
        assertTrue(ok);
        assertEq(lo, T0 + 1 days);
        assertEq(hi, T0 + 180 days);
    }

    function test_unpinnedKey_withoutApproval_fails() public view {
        (bool ok,,) = rail.keyAllowed(_claim(holder), KEY_C, "");
        assertFalse(ok);
    }

    // --- the Holder extends ---------------------------------------------------------------------------------

    /// The rotation the pinned model could not survive: the bank switched keys after the deal was
    /// activated, and nobody had pinned the new one. The Holder's own client checks it against the
    /// bank's DNS and signs — and the payment is provable again, with no redeploy and no authority.
    function test_holderApproval_rescuesAnUnplannedRotation() public view {
        (bool ok, uint64 lo, uint64 hi) = rail.keyAllowed(_claim(holder), KEY_C, _approve(holderPk, DEAL, KEY_C));
        assertTrue(ok);
        assertEq(lo, T0 + 1 days, "never before the deal existed");
        assertEq(hi, T0 + 1 days + rail.MAX_WINDOW(), "bounded like any pinned key");
    }

    /// A Holder that is a contract (a smart wallet) approves through EIP-1271, like every other consent.
    function test_contractHolder_approvesThrough1271() public {
        Mock1271 wallet = new Mock1271();
        wallet.setOk(true);
        (bool ok,,) = rail.keyAllowed(_claim(address(wallet)), KEY_C, hex"01");
        assertTrue(ok);
        wallet.setOk(false);
        (ok,,) = rail.keyAllowed(_claim(address(wallet)), KEY_C, hex"01");
        assertFalse(ok, "a wallet that does not vouch, does not extend");
    }

    // --- ... and cannot restrict ----------------------------------------------------------------------------

    /// There is no veto. A Holder able to switch off a genuine key could deny a real payment and take the
    /// principal home at the timeout, so whatever the Holder signs, a pinned key keeps counting.
    function test_holderCannotSwitchOffAPinnedKey() public view {
        bytes memory approvalOfAnotherKey = _approve(holderPk, DEAL, KEY_C);
        (bool ok,,) = rail.keyAllowed(_claim(holder), KEY_A, approvalOfAnotherKey);
        assertTrue(ok);
        (ok,,) = rail.keyAllowed(_claim(holder), KEY_A, hex"deadbeef");
        assertTrue(ok, "garbage in the approval slot changes nothing for a pinned key");
    }

    // --- nobody else can produce the extension ----------------------------------------------------------

    /// The Provider is the one a false key would PAY. Their signature is worth nothing here.
    function test_providerCannotApprove() public view {
        (bool ok,,) = rail.keyAllowed(_claim(holder), KEY_C, _approve(providerPk, DEAL, KEY_C));
        assertFalse(ok);
    }

    function test_approvalForAnotherDeal_fails() public view {
        (bool ok,,) = rail.keyAllowed(_claim(holder), KEY_C, _approve(holderPk, keccak256("other deal"), KEY_C));
        assertFalse(ok);
    }

    function test_approvalOfAnotherKey_fails() public view {
        (bool ok,,) =
            rail.keyAllowed(_claim(holder), KEY_C, _approve(holderPk, DEAL, keccak256("the key the Holder saw")));
        assertFalse(ok);
    }

    /// The approval names the adapter it was given to (EIP-712 `verifyingContract`): consent to a key
    /// for one rail is not consent for another.
    function test_approvalForAnotherRail_fails() public {
        RailKeysHarness otherRail = new RailKeysHarness(_oneAnchor());
        bytes32 digest = otherRail.keyApprovalDigest(DEAL, KEY_C);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPk, digest);
        (bool ok,,) = rail.keyAllowed(_claim(holder), KEY_C, abi.encodePacked(r, s, v));
        assertFalse(ok);
    }

    function test_zeroKey_neverCounts() public view {
        (bool ok,,) = rail.keyAllowed(_claim(holder), bytes32(0), _approve(holderPk, DEAL, bytes32(0)));
        assertFalse(ok);
    }

    // --- edges -----------------------------------------------------------------------------------------------

    function test_approvedWindow_saturatesInsteadOfWrapping() public view {
        IPaymentVerifier.PaymentClaim memory c = _claim(holder);
        c.notBefore = type(uint64).max - 1;
        (bool ok, uint64 lo, uint64 hi) = rail.keyAllowed(c, KEY_C, _approve(holderPk, DEAL, KEY_C));
        assertTrue(ok);
        assertEq(lo, type(uint64).max - 1);
        assertEq(hi, type(uint64).max);
    }

    // --- helpers ---------------------------------------------------------------------------------------------

    function _claim(address holder_) internal pure returns (IPaymentVerifier.PaymentClaim memory) {
        return IPaymentVerifier.PaymentClaim({dealId: DEAL, fiatCommit: FIAT, notBefore: T0 + 1 days, holder: holder_});
    }

    function _approve(uint256 pk, bytes32 dealId, bytes32 keyHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, rail.keyApprovalDigest(dealId, keyHash));
        return abi.encodePacked(r, s, v);
    }

    function _oneAnchor() internal pure returns (PinnedAnchors.Anchor[] memory a) {
        a = new PinnedAnchors.Anchor[](1);
        a[0] = PinnedAnchors.Anchor({keyHash: KEY_A, validFrom: T0, validUntil: T0 + 180 days});
    }
}
