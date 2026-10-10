// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RampIntent, RampQuote} from "../src/ramps/interfaces/IRamp.sol";
import {MockRamp} from "../mocks/MockRamp.sol";
import {MockStargate} from "../mocks/MockStargate.sol";
import {StargateV2Ramp} from "../src/ramps/StargateV2Ramp.sol";
import {StargateSepolia} from "../src/ramps/StargateSepolia.sol";
import {TestToken} from "../mocks/TestToken.sol";

contract RampTest is Test {
    uint256 internal constant AMOUNT = 1_000_000;
    uint256 internal constant NATIVE_FEE = 0.001 ether;
    uint32 internal constant DEST = 40161;

    TestToken internal token;
    address internal user = address(0xA11CE);
    address internal destWallet = address(0xB0B);
    address internal refund = address(0x1111);

    function setUp() public {
        token = new TestToken();
        token.mint(user, AMOUNT * 4);
        vm.deal(user, 1 ether);
    }

    function test_quote_returnsNativeFeeAndAmountOut() public {
        MockRamp ramp = new MockRamp(address(token), NATIVE_FEE, 0);
        RampQuote memory q = ramp.quote(_intent(AMOUNT, 0));
        assertEq(q.nativeFee, NATIVE_FEE);
        assertEq(q.amountOut, AMOUNT);
    }

    function test_send_creditsTo_adapterEmpty() public {
        MockRamp ramp = new MockRamp(address(token), NATIVE_FEE, 0);
        _approve(user, address(ramp));
        vm.prank(user);
        ramp.send{value: NATIVE_FEE}(_intent(AMOUNT, AMOUNT));
        assertEq(token.balanceOf(destWallet), AMOUNT);
        assertEq(token.balanceOf(address(ramp)), 0);
        assertEq(address(ramp).balance, 0);
    }

    function test_send_zeroProtocolFee_haircutGoesToInfra() public {
        MockRamp ramp = new MockRamp(address(token), NATIVE_FEE, 100);
        uint256 out = AMOUNT - AMOUNT / 100;
        _approve(user, address(ramp));
        vm.prank(user);
        ramp.send{value: NATIVE_FEE}(_intent(AMOUNT, out));
        assertEq(token.balanceOf(destWallet), out);
        assertEq(token.balanceOf(address(ramp)), 0);
        assertEq(token.balanceOf(ramp.infra()), AMOUNT - out);
    }

    function test_send_refundsExcessNative() public {
        MockRamp ramp = new MockRamp(address(token), NATIVE_FEE, 0);
        _approve(user, address(ramp));
        uint256 before = refund.balance;
        vm.prank(user);
        ramp.send{value: NATIVE_FEE + 0.05 ether}(_intent(AMOUNT, AMOUNT));
        assertEq(refund.balance, before + 0.05 ether);
        assertEq(address(ramp).balance, 0);
    }

    function test_send_revertsIfNativeShort() public {
        MockRamp ramp = new MockRamp(address(token), NATIVE_FEE, 0);
        _approve(user, address(ramp));
        vm.prank(user);
        vm.expectRevert(MockRamp.InsufficientNativeFee.selector);
        ramp.send{value: NATIVE_FEE - 1}(_intent(AMOUNT, AMOUNT));
    }

    function test_stargateRamp_quoteUsesPool() public {
        MockStargate pool = new MockStargate(address(token), NATIVE_FEE, 1_000);
        StargateV2Ramp ramp = new StargateV2Ramp(address(pool));
        RampQuote memory q = ramp.quote(_intent(AMOUNT, 0));
        assertEq(q.nativeFee, NATIVE_FEE);
        assertEq(q.amountOut, AMOUNT - 1_000);
    }

    function test_stargateRamp_send_adapterEmpty() public {
        MockStargate pool = new MockStargate(address(token), NATIVE_FEE, 1_000);
        StargateV2Ramp ramp = new StargateV2Ramp(address(pool));
        _approve(user, address(ramp));
        uint256 out = AMOUNT - 1_000;
        vm.prank(user);
        ramp.send{value: NATIVE_FEE}(_intent(AMOUNT, out));
        assertEq(token.balanceOf(destWallet), out);
        assertEq(token.balanceOf(address(ramp)), 0);
        assertEq(address(ramp).balance, 0);
    }

    function test_stargateRamp_revertsIfTokenMismatch() public {
        MockStargate pool = new MockStargate(address(token), NATIVE_FEE, 0);
        StargateV2Ramp ramp = new StargateV2Ramp(address(pool));
        RampIntent memory intent = _intent(AMOUNT, AMOUNT);
        intent.token = address(0xBAD);
        vm.prank(user);
        vm.expectRevert(StargateV2Ramp.TokenMismatch.selector);
        ramp.send{value: NATIVE_FEE}(intent);
    }

    function test_stargateRamp_revertsIfAmountOutBelowMin() public {
        MockStargate pool = new MockStargate(address(token), NATIVE_FEE, 1_000);
        StargateV2Ramp ramp = new StargateV2Ramp(address(pool));
        _approve(user, address(ramp));
        vm.prank(user);
        vm.expectRevert(StargateV2Ramp.InsufficientAmountOut.selector);
        ramp.send{value: NATIVE_FEE}(_intent(AMOUNT, AMOUNT));
    }

    function test_sepoliaUsdcPoolConstant() public pure {
        assertEq(StargateSepolia.USDC_POOL, 0x543BdA7c6cA4384FE90B1F5929bb851F52888983);
        assertEq(StargateSepolia.USDC, 0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773);
        assertEq(StargateSepolia.EID, 40231);
    }

    function _intent(uint256 amount, uint256 minOut) internal view returns (RampIntent memory) {
        return RampIntent({
            token: address(token), amount: amount, minAmountOut: minOut, dest: DEST, to: destWallet, refund: refund
        });
    }

    function _approve(address owner, address spender) internal {
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
    }
}
