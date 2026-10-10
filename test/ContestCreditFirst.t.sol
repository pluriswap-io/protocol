// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {ArbitrationMock} from "../mocks/ArbitrationMock.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

/// @title The contest fee is credit-first, like every other payout
/// @notice Evaluation of 2026-09-28: `_pullFee` pushed the contest straight to its recipient, so a recipient
///         the token refuses (a USDC blacklist, a paused recipient) made `openDisputed` and `openCourt` revert.
///         The Holder lost the freeze and the Provider could `claim`. A fee recipient is never allowed to
///         block the Holder's only defence: the fee is pulled, then credited, then pushed if it can be.
contract ContestCreditFirstTest is BaseTest {
    uint256 internal constant CONTEST = 30_000;
    address internal constant RECIPIENT = address(0xC0F);

    BlockingToken internal blocking;
    ArbitrationMock internal court;

    function setUp() public override {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);
        controller = vm.addr(controllerPk);
        blocking = new BlockingToken();
        token = blocking;
        escrow = new Escrow(address(0), 0, 0);
        court =
            new ArbitrationMock(address(0x71B), address(blocking), 0, 1 days, address(escrow), CONTEST, RECIPIENT, 0);
        token.mint(holder, PRINCIPAL + CONTEST);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);
    }

    function test_blockedRecipient_doesNotBlockTheFreeze() public {
        bytes32 id = _activateWithCourt(1, 2);
        _markFiat(id);
        blocking.block_(RECIPIENT);
        vm.prank(holder);
        escrow.openDisputed(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.DISPUTED), "the Holder still froze the trade");
        assertEq(escrow.creditOf(address(token), RECIPIENT), CONTEST, "the fee waits in credit");
    }

    function test_blockedRecipient_doesNotBlockTheCourt() public {
        bytes32 id = _activateWithCourt(3, 4);
        _markFiat(id);
        blocking.block_(RECIPIENT);
        vm.prank(holder);
        escrow.openCourt(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.ARBITRATION_ACTIVE));
        assertEq(escrow.creditOf(address(token), RECIPIENT), CONTEST);
    }

    function _activateWithCourt(uint256 hNonce, uint256 pNonce) internal returns (bytes32) {
        DealTerms memory terms = _p2pTerms();
        terms.arbitrationDuration = 1 days;
        terms.packageIds = new bytes32[](1);
        terms.packageIds[0] = court.packageId();
        PackageMods memory mods;
        mods.court = address(court);
        HolderAuthorization memory ha = _holderAuth(terms, hNonce);
        ProviderAgreement memory pa = _providerAuth(terms, pNonce);
        ControllerAcceptance memory ca;
        return escrow.activate(ha, _signHolder(ha), pa, _signProvider(pa), ca, "", mods);
    }
}

/// @dev A token that refuses transfers to addresses it was told to block, as a stablecoin blacklist does.
contract BlockingToken is TestToken {
    error Blocked();

    mapping(address => bool) public blocked;

    function block_(address a) external {
        blocked[a] = true;
    }

    function unblock(address a) external {
        blocked[a] = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert Blocked();
        super._update(from, to, value);
    }
}
