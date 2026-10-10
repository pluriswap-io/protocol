// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods,
    PackageData
} from "../src/libraries/Types.sol";
import {Packages} from "../src/libraries/Packages.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";
import {BaseTest} from "./Base.t.sol";

/// @title A court learns its deal at activation, and is paid for being available
/// @notice PROTOCOLO.md Anexo R, 2026-09-28: the panel is fixed during the negotiation, so the court has to know the
///         deal — and who will judge it — before the principal is in custody. The kernel hands it its opaque data
///         at activation (`bind`), and pulls from the Holder the court's availability share, which the court's
///         `packageId` binds like every other price.
contract CourtActivationTest is BaseTest {
    BindingCourt internal court;

    function setUp() public override {
        super.setUp();
        court = new BindingCourt(address(escrow), address(token), 60); // 0.6%: three arbiters at 0.2%
        token.mint(holder, PRINCIPAL);
    }

    function test_activation_paysTheCourtItsShare_andBindsTheDeal() public {
        DealTerms memory terms = _p2pTerms();
        terms.arbitrationDuration = 1 days;
        terms.packageIds = new bytes32[](1);
        terms.packageIds[0] = court.packageId();
        PackageMods memory mods;
        mods.court = address(court);
        PackageData memory data;
        data.court = abi.encode("the panel");
        HolderAuthorization memory ha = _holderAuth(terms, 1);
        ProviderAgreement memory pa = _providerAuth(terms, 2);
        ControllerAcceptance memory ca;
        bytes memory hs = _signHolder(ha);
        bytes memory ps = _signProvider(pa);
        uint256 share = PRINCIPAL * 60 / 10_000;
        bytes32 expected = Consent.dealId(escrow.domainSeparator(), terms, 1, 2, 0);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Packages.FeeCharged(expected, Packages.FeeKind.Activation, address(court), share);
        bytes32 id = escrow.activate(ha, hs, pa, ps, ca, "", mods, data);
        assertEq(token.balanceOf(address(court)), share, "the court holds the availability share");
        assertEq(court.boundDeal(), id, "the court learned its deal");
        assertEq(court.boundFee(), share);
        assertEq(court.boundData(), abi.encode("the panel"));
        assertEq(court.boundPrincipal(), PRINCIPAL);
    }
}

/// @dev A court that records what the kernel told it at activation.
contract BindingCourt is ArbitrationMock {
    bytes32 public boundDeal;
    uint256 public boundFee;
    uint256 public boundPrincipal;
    bytes public boundData;

    constructor(address escrow_, address token_, uint256 bps)
        ArbitrationMock(address(0x71B), token_, 0, 1 days, escrow_, 0, address(0), bps)
    {}

    function bind(
        bytes32 dealId,
        DealTerms calldata t,
        uint256 fee,
        bytes calldata data,
        bytes calldata,
        bytes calldata
    ) external override {
        boundDeal = dealId;
        boundFee = fee;
        boundPrincipal = t.principal;
        boundData = data;
    }
}
