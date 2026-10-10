// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    PackageMods,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance
} from "../src/libraries/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BaseTest} from "./Base.t.sol";

/// @dev A REPUTATION module that answers `activationFee() == 0` to every read until `admit` runs, and then
///      charges its real fee. `Packages.resolve` validates the signed `packageId` against the zero, and
///      `engage` calls `admit` twice -- which is not `view` -- before it reads the fee it is going to pull.
contract FlipFeeReputation is IReputation {
    error Unauthorized();

    IPassport public immutable passport;
    address public immutable operator;
    address public immutable feeRecipient;
    uint256 public immutable completionBps;
    uint256 public immutable realActivationFee;
    bool public flipped;

    constructor(IPassport passport_, address feeRecipient_, uint256 realFee, address operator_) {
        passport = passport_;
        feeRecipient = feeRecipient_;
        completionBps = 0;
        realActivationFee = realFee;
        operator = operator_;
    }

    /// What the parties signed: this module, this recipient, zero activation fee, zero completion fee.
    function packageId() external view returns (bytes32) {
        return PackageId.reputation(address(this), feeRecipient, 0, 0, 0, 0);
    }

    function activationBps() external view returns (uint256) {
        return flipped ? realActivationFee : 0;
    }

    function invoiceActivation(uint256) external view returns (uint256 amount, address recipient) {
        return (flipped ? realActivationFee : 0, feeRecipient);
    }

    function invoiceCompletion(uint256) external view returns (uint256 amount, address recipient) {
        return (0, feeRecipient);
    }

    function contestBps() external pure returns (uint256) {
        return 0;
    }

    function contestFloor() external pure returns (uint256) {
        return 0;
    }

    function invoiceContest(uint256) external view returns (uint256 amount, address recipient) {
        return (0, feeRecipient);
    }

    /// The mutation lands between `resolve`'s validation and `engage`'s fee read.
    function admit(address wallet, bytes32, address, uint256, address, bytes calldata)
        external
        returns (bytes32 subject)
    {
        if (msg.sender != operator) revert Unauthorized();
        flipped = true;
        subject = passport.identify(wallet, wallet, bytes32(0), "");
    }

    function notifyTerminal(bytes32, bytes32, address, uint256, IReputation.Close) external {}
}

contract EngageActivationFeeTest is BaseTest {
    PassportMock internal passport;
    address internal feeRecipient = address(0xFEE);

    function setUp() public override {
        super.setUp();
        passport = new PassportMock();
        passport.setHuman(holder, keccak256("human-h"));
        passport.setHuman(provider, keccak256("human-p"));
    }

    /// The activation fee is inside the signed `packageId` preimage, so charging it is supposed to be
    /// consented to. `resolve` validates one read of the policy, and `admit` -- which is not `view` -- runs
    /// twice before the pull, so a module could be signed as free and answer a fee by the time it is paid.
    /// Since 2026-10-06 the kernel pulls the copy `resolve` bound to the signed id (`Deal.prices`) and never
    /// reads the fee again: the flip happens, and nobody pays it.
    function test_engage_chargesTheSignedActivationFee_notALaterRead() public {
        uint256 stealthBps = 2_500; // 25%
        uint256 stealthFee = PRINCIPAL * stealthBps / 10_000;
        FlipFeeReputation hostile = new FlipFeeReputation(passport, feeRecipient, stealthBps, address(escrow));
        // Fund the stealth fee on purpose: the only thing standing between the Holder and an unsigned fee is the
        // copy, not a balance that happens to be too small.
        token.mint(holder, stealthFee);

        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), hostile.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(hostile);

        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes memory holderSig = _signHolder(ha);
        bytes memory providerSig = _signProvider(pa);

        uint256 holderBefore = IERC20(address(token)).balanceOf(holder);
        bytes32 id = escrow.activate(ha, holderSig, pa, providerSig, ca, "", mods);

        assertTrue(hostile.flipped(), "the module did flip");
        assertEq(
            holderBefore - IERC20(address(token)).balanceOf(holder),
            terms.principal + PRINCIPAL * escrow.activationBps() / 10_000,
            "the principal and the kernel's share, nothing else"
        );
        assertEq(IERC20(address(token)).balanceOf(feeRecipient), 0, "the stealth fee was not paid");
        assertEq(escrow.pricesOf(id).repActivationBps, 0, "the deal keeps the fee it signed");
    }

    /// The check rejects a policy that stopped matching, not a module that simply charges something. An
    /// honest non-zero activation fee still activates and still gets paid.
    function test_engage_acceptsHonestNonZeroActivationFee() public {
        uint256 actBps = 2_500;
        uint256 actFee = PRINCIPAL * actBps / 10_000;
        Reputation honest = new Reputation(passport, feeRecipient, actBps, 0, 0, 0, address(escrow));
        token.mint(holder, actFee);

        DealTerms memory terms = _p2pTerms();
        terms.packageIds = _sorted2(passport.packageId(), honest.packageId());
        PackageMods memory mods;
        mods.passport = address(passport);
        mods.reputation = address(honest);

        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 1);
        ControllerAcceptance memory ca;
        bytes32 id = escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods);

        assertEq(uint8(escrow.status(id)), uint8(Status.FUNDED));
        assertEq(IERC20(address(token)).balanceOf(feeRecipient), actFee, "the signed fee was charged");
    }

    function _sorted2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        if (uint256(a) < uint256(b)) {
            ids[0] = a;
            ids[1] = b;
        } else {
            ids[0] = b;
            ids[1] = a;
        }
    }
}
