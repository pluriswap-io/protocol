// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {BaseTest} from "./Base.t.sol";

/// @title The official fees are a share of the principal
/// @notice PROTOCOLO.md Anexo R, 2026-09-28: 0.3% of the principal from the Holder at activation, 0.3% from the
///         pot at completion. A flat fee is regressive — the same cents on 250 and on 5,000 — and a module
///         that wants a share has to be told the principal, so the policy is in basis points and the kernel
///         does the arithmetic on the principal the parties signed.
contract ProportionalFeesTest is BaseTest {
    uint256 internal constant BPS = 30; // 0.3%
    address internal constant FEE_TO = address(0xFEE);
    bytes32 internal constant SUB_H = keccak256("human-h");
    bytes32 internal constant SUB_P = keccak256("human-p");

    PassportMock internal passport;
    BpsReputation internal reputation;

    function setUp() public override {
        super.setUp();
        passport = new PassportMock();
        reputation = new BpsReputation(passport, FEE_TO, BPS, BPS, address(escrow));
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        token.mint(holder, PRINCIPAL); // room for the activation fee on top of the principal
    }

    function test_activation_chargesTheHolderAShareOfThePrincipal() public {
        _activate(1, 2);
        assertEq(token.balanceOf(FEE_TO), PRINCIPAL * BPS / 10_000, "0.3% of the principal, on top of it");
    }

    function test_completion_takesAShareOfThePot() public {
        bytes32 id = _activate(3, 4);
        _markFiat(id);
        vm.prank(holder);
        escrow.release(id);
        uint256 share = PRINCIPAL * BPS / 10_000;
        assertEq(token.balanceOf(provider), PRINCIPAL - share, "the Provider nets the pot minus 0.3%");
        assertEq(token.balanceOf(FEE_TO), 2 * share, "activation and completion, 0.3% each");
    }

    /// A refund is not a trade: the Provider's cancel pays no completion, and the activation stays paid.
    function test_refund_paysOnlyTheActivation() public {
        bytes32 id = _activate(5, 6);
        vm.prank(provider);
        escrow.cancelByProvider(id);
        assertEq(token.balanceOf(FEE_TO), PRINCIPAL * BPS / 10_000);
    }

    function test_invoices_quoteTheShareOfAGivenPrincipal() public view {
        (uint256 act, address to) = reputation.invoiceActivation(250e6);
        (uint256 comp,) = reputation.invoiceCompletion(250e6);
        assertEq(act, 750_000, "0.3% of 250");
        assertEq(comp, 750_000);
        assertEq(to, FEE_TO);
    }

    function _activate(uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
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

/// @dev A reputation module whose whole policy is two shares of the principal.
contract BpsReputation is IReputation {
    error Unauthorized();

    IPassport public immutable passport;
    address public immutable feeRecipient;
    uint256 public immutable activationBps;
    uint256 public immutable completionBps;
    uint256 public constant contestBps = 0;
    uint256 public constant contestFloor = 0;
    address public immutable operator;
    bytes32 public immutable packageId;

    constructor(
        IPassport passport_,
        address feeRecipient_,
        uint256 activationBps_,
        uint256 completionBps_,
        address op
    ) {
        passport = passport_;
        feeRecipient = feeRecipient_;
        activationBps = activationBps_;
        completionBps = completionBps_;
        operator = op;
        packageId = PackageId.reputation(address(this), feeRecipient_, activationBps_, completionBps_, 0, 0);
    }

    function invoiceActivation(uint256 principal) external view returns (uint256 amount, address recipient) {
        return (principal * activationBps / 10_000, feeRecipient);
    }

    function invoiceCompletion(uint256 principal) external view returns (uint256 amount, address recipient) {
        return (principal * completionBps / 10_000, feeRecipient);
    }

    function invoiceContest(uint256) external view returns (uint256 amount, address recipient) {
        return (0, feeRecipient);
    }

    function admit(address wallet, bytes32 dealId, address, uint256, address, bytes calldata data)
        external
        returns (bytes32)
    {
        if (msg.sender != operator) revert Unauthorized();
        return passport.identify(wallet, wallet, dealId, data);
    }

    function notifyTerminal(bytes32, bytes32, address, uint256, IReputation.Close) external view {
        if (msg.sender != operator) revert Unauthorized();
    }
}
