// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";
import {PackageId} from "../src/libraries/PackageId.sol";

contract ArbitrationMockTest is Test {
    uint256 internal constant COURT_FEE = 1_000_000;
    uint256 internal constant DURATION = 1 days;
    bytes32 internal constant DEAL = keccak256("deal-arb");

    TestToken internal token;
    ArbitrationMock internal arb;
    address internal tribunal = address(0x71B);
    address internal controller = address(0xC0);
    address internal provider = address(0xB0B);

    function setUp() public {
        token = new TestToken();
        arb = new ArbitrationMock(tribunal, address(token), COURT_FEE, DURATION, address(0), 0, address(0xFEE), 0);
        token.mint(controller, COURT_FEE * 4);
        vm.prank(controller);
        token.approve(address(arb), type(uint256).max);
    }

    function test_packageId_arbitrationStable() public view {
        assertEq(arb.packageId(), PackageId.arbitration(address(arb), tribunal, COURT_FEE, 0, address(0xFEE), 0, 0));
    }

    function test_onlyControllerOpens() public {
        vm.prank(provider);
        vm.expectRevert(ArbitrationMock.Unauthorized.selector);
        arb.open(DEAL, controller);

        vm.prank(controller);
        arb.open(DEAL, controller);
        assertEq(arb.controllerOf(DEAL), controller);
        assertEq(token.balanceOf(tribunal), COURT_FEE);
        assertEq(token.balanceOf(controller), COURT_FEE * 3);
    }

    function test_rulingTernary() public {
        _open(DEAL);
        vm.expectRevert(ArbitrationMock.InvalidRuling.selector);
        arb.submitRuling(DEAL, ArbitrationMock.Ruling.None);
        arb.submitRuling(DEAL, ArbitrationMock.Ruling.HolderWin);
        assertEq(uint8(arb.rulingOf(DEAL)), uint8(ArbitrationMock.Ruling.HolderWin));

        bytes32 d2 = keccak256("deal-2");
        _open(d2);
        arb.submitRuling(d2, ArbitrationMock.Ruling.ProviderWin);
        assertEq(uint8(arb.rulingOf(d2)), uint8(ArbitrationMock.Ruling.ProviderWin));

        bytes32 d3 = keccak256("deal-3");
        _open(d3);
        arb.submitRuling(d3, ArbitrationMock.Ruling.Stalemate);
        assertEq(uint8(arb.rulingOf(d3)), uint8(ArbitrationMock.Ruling.Stalemate));
    }

    function test_timeoutStalemate() public {
        _open(DEAL);
        vm.expectRevert(ArbitrationMock.DeadlineNotDue.selector);
        arb.forceTimeout(DEAL);
        vm.warp(block.timestamp + DURATION);
        vm.prank(provider);
        arb.forceTimeout(DEAL);
        assertEq(uint8(arb.rulingOf(DEAL)), uint8(ArbitrationMock.Ruling.Stalemate));
    }

    function _open(bytes32 dealId) internal {
        vm.prank(controller);
        arb.open(dealId, controller);
    }
}
