// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ChainIds} from "./ChainIds.s.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";
import {IGitcoinPassportDecoder} from "../src/packages/interfaces/IGitcoinPassportDecoder.sol";
import {HumanPassport} from "../mocks/HumanPassport.sol";
import {PassportMock} from "../mocks/PassportMock.sol";

/// @dev Picks the PASSPORT adapter for the chain being deployed to.
///      - Arbitrum One, or any chain with `PASSPORT_DECODER` set: `HumanPassport` over the official
///        Human Passport decoder (`PASSPORT_MIN_SCORE`, 4 decimals, 0 = decoder's own threshold).
///      - Otherwise (Arbitrum Sepolia, anvil): `PassportMock`, the lab tool; never a production identity, and
///        refused by `_requireMockChain` on any chain that is not a known test chain.
///      Exactly one CREATE either way, so callers' nonce predictions hold.
abstract contract PassportPicker is ChainIds {
    address internal constant HUMAN_PASSPORT_DECODER_ARBITRUM = 0x2050256A91cbABD7C42465aA0d5325115C1dEB43;

    function _deployPassport() internal returns (IPassport passport, address decoder) {
        decoder = vm.envOr("PASSPORT_DECODER", address(0));
        if (decoder == address(0) && block.chainid == ARBITRUM_ONE) decoder = HUMAN_PASSPORT_DECODER_ARBITRUM;
        if (decoder != address(0)) {
            require(decoder.code.length > 0, "passport decoder has no code on this chain");
            uint256 minScore = vm.envOr("PASSPORT_MIN_SCORE", uint256(0));
            passport = new HumanPassport(IGitcoinPassportDecoder(decoder), minScore);
        } else {
            // `PassportMock.setHuman` is an unauthenticated setter and `BondVault.withdraw` authorises through
            // `passport.identify(msg.sender)`, so a mock passport on a live chain hands every bond to anyone.
            _requireMockChain("PassportMock");
            passport = new PassportMock();
        }
    }
}
