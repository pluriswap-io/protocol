// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {FeeOnTransferToken} from "../mocks/FeeOnTransferToken.sol";
import {RevertingReceiver, TokenThatRejectsReceiver} from "../mocks/RevertingReceiver.sol";
import {Settlement} from "../src/libraries/Settlement.sol";

contract SettlementHarness {
    Settlement.Store internal store;

    function pullExact(address token, address from, uint256 principal) external {
        Settlement.pullExact(token, from, principal);
    }

    function creditThenTryPush(address token, address to, uint256 amount) external {
        Settlement.creditThenTryPush(store, token, to, amount);
    }

    function creditOf(address token, address beneficiary) external view returns (uint256) {
        return Settlement.creditOf(store, token, beneficiary);
    }

    function withdraw(address token) external {
        Settlement.withdraw(store, token, msg.sender);
    }
}

contract SettlementTest is Test {
    TestToken internal token;
    SettlementHarness internal harness;
    address internal holder = address(0xA11CE);

    uint256 internal constant PRINCIPAL = 1_000_000;

    function setUp() public {
        token = new TestToken();
        harness = new SettlementHarness();
        token.mint(holder, PRINCIPAL);
        vm.prank(holder);
        token.approve(address(harness), PRINCIPAL);
    }

    function test_pullExact_movesPrincipal() public {
        vm.prank(holder);
        harness.pullExact(address(token), holder, PRINCIPAL);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(harness)), PRINCIPAL);
    }

    function test_pullExact_revertsIfFeeOnTransfer() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(holder, PRINCIPAL);
        vm.prank(holder);
        feeToken.approve(address(harness), PRINCIPAL);

        vm.prank(holder);
        vm.expectRevert(Settlement.InexactPull.selector);
        harness.pullExact(address(feeToken), holder, PRINCIPAL);

        assertEq(feeToken.balanceOf(address(harness)), 0);
    }

    function test_creditThenTryPush_success() public {
        address provider = address(0xB0B);
        token.mint(address(harness), PRINCIPAL);
        harness.creditThenTryPush(address(token), provider, PRINCIPAL);
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(harness.creditOf(address(token), provider), 0);
    }

    function test_creditThenTryPush_revertingReceiverKeepsCredit() public {
        RevertingReceiver sink = new RevertingReceiver();
        TokenThatRejectsReceiver rejecting = new TokenThatRejectsReceiver(address(sink));
        rejecting.mint(address(harness), PRINCIPAL);

        harness.creditThenTryPush(address(rejecting), address(sink), PRINCIPAL);

        assertEq(rejecting.balanceOf(address(sink)), 0);
        assertEq(rejecting.balanceOf(address(harness)), PRINCIPAL);
        assertEq(harness.creditOf(address(rejecting), address(sink)), PRINCIPAL);
    }

    function test_withdraw_paysBeneficiary() public {
        address provider = address(0xB0B);
        token.mint(address(harness), PRINCIPAL);
        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.transfer, (provider, PRINCIPAL)), "blocked");
        harness.creditThenTryPush(address(token), provider, PRINCIPAL);
        assertEq(harness.creditOf(address(token), provider), PRINCIPAL);
        vm.clearMockedCalls();

        vm.prank(provider);
        harness.withdraw(address(token));
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(harness.creditOf(address(token), provider), 0);
    }

    function test_withdraw_revertingKeepsCredit() public {
        address provider = address(0xB0B);
        token.mint(address(harness), PRINCIPAL);
        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.transfer, (provider, PRINCIPAL)), "blocked");
        harness.creditThenTryPush(address(token), provider, PRINCIPAL);

        vm.prank(provider);
        vm.expectRevert();
        harness.withdraw(address(token));

        assertEq(harness.creditOf(address(token), provider), PRINCIPAL);
        assertEq(token.balanceOf(address(harness)), PRINCIPAL);
        assertEq(token.balanceOf(provider), 0);
    }
}
