// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HumanPassport} from "../../mocks/HumanPassport.sol";
import {IGitcoinPassportDecoder} from "../../src/packages/interfaces/IGitcoinPassportDecoder.sol";
import {IPassport} from "../../src/packages/interfaces/IPassport.sol";

/// @dev Arbitrum One fork against the official Human Passport decoder. Skipped unless ARBITRUM_RPC_URL is set.
///      Set HUMAN_WALLET to an address with a live passing score to exercise the positive path.
contract HumanPassportForkTest is Test {
    address internal constant DECODER = 0x2050256A91cbABD7C42465aA0d5325115C1dEB43;

    IGitcoinPassportDecoder internal decoder = IGitcoinPassportDecoder(DECODER);
    HumanPassport internal passport;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        passport = new HumanPassport(decoder, 0);
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    function test_fork_decoderIsLive() public onFork {
        assertGt(DECODER.code.length, 0, "decoder has no code on Arbitrum One");
        assertGt(decoder.threshold(), 0, "decoder threshold unset");
        assertGt(decoder.maxScoreAge(), 0, "decoder maxScoreAge unset");
    }

    function test_fork_unknownWalletIsNotHuman() public onFork {
        address nobody = address(uint160(uint256(keccak256("pluriswap.nobody"))));
        assertFalse(passport.isHuman(nobody));
        vm.expectRevert(IPassport.NoPassport.selector);
        passport.identify(nobody, nobody, bytes32(0), "");
    }

    function test_fork_knownHumanIdentifies() public onFork {
        address human = vm.envOr("HUMAN_WALLET", address(0));
        vm.skip(human == address(0));
        assertTrue(passport.isHuman(human), "HUMAN_WALLET has no live passing score");
        assertEq(passport.identify(human, human, bytes32(0), ""), bytes32(uint256(uint160(human))));
        (uint256 s, bool live) = passport.score(human);
        assertTrue(live);
        assertGe(s, decoder.threshold());
    }
}
