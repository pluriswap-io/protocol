// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IReabsorbVerifier} from "../src/packages/interfaces/IReabsorbVerifier.sol";

/// @dev Mock behind the frozen `IReabsorbVerifier`: decodes the proof as the verdict. A passing
///      mock is not a proof.
contract ReabsorbVerifierMock is IReabsorbVerifier {
    function verifyReabsorb(
        bytes32,
        bytes32,
        address,
        uint256,
        uint256,
        bytes32,
        bytes32,
        bytes32,
        bytes calldata proof
    ) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
