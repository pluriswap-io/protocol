// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {BaseTest} from "./Base.t.sol";

/// @title A Provider who never shows up pays for it in reputation
/// @notice PROTOCOLO.md Anexo R, 2026-09-28 ("No presentarse cuesta reputación").
/// @dev The Holder's activation fee is charged always, cancelled deals included. Without a mark, a Provider
///      who accepts and never pays costs the Holder that fee and himself nothing. So both unilateral ways out
///      of FUNDED — the fiat clock running out and the Provider cancelling on his own — close his side as
///      `NoShow` (+5). The mutual cancel stays `Silent` for both: it is the free exit of an honest Provider
///      who cannot pay, and it needs the Holder's signature. Penalising the unilateral cancel too is what
///      stops a Provider from cancelling a minute before the clock.
contract NoShowTest is BaseTest {
    /// `IReputation.Close.NoShow`, the value the decision appends after `Deadlock`.
    uint8 internal constant NO_SHOW = 6;
    uint8 internal constant SILENT = uint8(IReputation.Close.Silent);
    bytes32 internal constant SUB_H = keccak256("human-h");
    bytes32 internal constant SUB_P = keccak256("human-p");

    PassportMock internal passport;
    RecordingReputation internal reputation;

    function setUp() public override {
        super.setUp();
        passport = new PassportMock();
        reputation = new RecordingReputation(passport, address(escrow));
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
    }

    function test_fiatClockRunsOut_marksTheProviderNoShow() public {
        bytes32 id = _activateWithReputation(1, 2);
        vm.warp(block.timestamp + 3600);
        escrow.timeoutFiat(id);
        assertEq(reputation.closeOf(SUB_P), NO_SHOW, "the side that never paid");
        assertEq(reputation.closeOf(SUB_H), SILENT, "the side that waited did nothing wrong");
    }

    function test_providerCancelsOnHisOwn_marksTheProviderNoShow() public {
        bytes32 id = _activateWithReputation(3, 4);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(reputation.closeOf(SUB_P), NO_SHOW, "cancelling a minute before the clock is still not showing up");
        assertEq(reputation.closeOf(SUB_H), SILENT);
    }

    /// The honest Provider's way out: ask, and have the Holder sign.
    function test_mutualCancel_marksNobody() public {
        bytes32 id = _activateWithReputation(5, 6);
        _mutualCancel(id, 7, 8);
        assertEq(reputation.closeOf(SUB_P), SILENT);
        assertEq(reputation.closeOf(SUB_H), SILENT);
    }

    function _activateWithReputation(uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
        DealTerms memory terms = _p2pTerms();
        (bytes32 a, bytes32 b) = (passport.packageId(), reputation.packageId());
        terms.packageIds = new bytes32[](2);
        (terms.packageIds[0], terms.packageIds[1]) = a < b ? (a, b) : (b, a);
        PackageMods memory mods = _mods(address(passport), address(reputation));
        HolderAuthorization memory ha = _holderAuth(terms, hNonce);
        ProviderAgreement memory pa = _providerAuth(terms, pNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods);
    }
}

/// @dev A free reputation module that remembers the last close the kernel reported for each subject,
///      stored as `kind + 1` so that "never notified" reads as zero.
contract RecordingReputation is IReputation {
    error Unauthorized();

    IPassport public immutable passport;
    address public immutable operator;
    address public constant feeRecipient = address(0xFEE);
    uint256 public constant activationBps = 0;
    uint256 public constant completionBps = 0;
    uint256 public constant contestBps = 0;
    uint256 public constant contestFloor = 0;
    bytes32 public immutable packageId;

    mapping(bytes32 subject => uint8 kindPlusOne) internal _close;

    constructor(IPassport passport_, address operator_) {
        passport = passport_;
        operator = operator_;
        packageId = PackageId.reputation(address(this), feeRecipient, 0, 0, 0, 0);
    }

    function closeOf(bytes32 subject) external view returns (uint8) {
        uint8 k = _close[subject];
        return k == 0 ? type(uint8).max : k - 1;
    }

    function invoiceActivation(uint256) external pure returns (uint256 amount, address recipient) {
        return (0, feeRecipient);
    }

    function invoiceCompletion(uint256) external pure returns (uint256 amount, address recipient) {
        return (0, feeRecipient);
    }

    function invoiceContest(uint256) external pure returns (uint256 amount, address recipient) {
        return (0, feeRecipient);
    }

    function admit(address wallet, bytes32, address, uint256, address, bytes calldata)
        external
        returns (bytes32 subject)
    {
        if (msg.sender != operator) revert Unauthorized();
        subject = passport.identify(wallet, wallet, bytes32(0), "");
    }

    function notifyTerminal(bytes32 subject, bytes32, address, uint256, IReputation.Close kind) external {
        if (msg.sender != operator) revert Unauthorized();
        _close[subject] = uint8(kind) + 1;
    }
}
