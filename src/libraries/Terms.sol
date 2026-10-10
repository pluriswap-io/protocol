// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DealTerms} from "./Types.sol";

library Terms {
    bytes32 internal constant DEAL_TERMS_TYPEHASH = keccak256(
        "DealTerms(address holder,address controller,address provider,address token,uint256 principal,uint256 fiatDuration,uint256 releaseDuration,uint256 disputeDuration,uint256 arbitrationDuration,bytes32 fiatCommit,bytes32[] packageIds)"
    );

    error UnsortedPackageIds();
    error HolderEqualsProvider();
    error ControllerEqualsProvider();
    error ZeroPrincipal();
    error ZeroAddress();
    error DurationTooLong();

    /// @dev No clock may run past uint64 seconds (~584 billion years). The bound is not an opinion about how
    ///      long a bank transfer takes — that stays the parties' (§E.3.8) — it is what keeps `origin + duration`
    ///      from overflowing, which would turn a long timeout into an impossible one.
    uint256 internal constant MAX_DURATION = type(uint64).max;

    /// @dev Terms that cannot hash cannot be signed: the four roles are non-zero, the Provider is neither
    ///      the Holder nor the Controller (it would release to itself), principal is non-zero, ids are canonical.
    function hashTerms(DealTerms memory t) public pure returns (bytes32) {
        if (t.holder == address(0) || t.controller == address(0) || t.provider == address(0) || t.token == address(0)) {
            revert ZeroAddress();
        }
        if (t.holder == t.provider) revert HolderEqualsProvider();
        if (t.controller == t.provider) revert ControllerEqualsProvider();
        if (t.principal == 0) revert ZeroPrincipal();
        if (
            t.fiatDuration > MAX_DURATION || t.releaseDuration > MAX_DURATION || t.disputeDuration > MAX_DURATION
                || t.arbitrationDuration > MAX_DURATION
        ) {
            revert DurationTooLong();
        }
        _assertPackageIdsCanonical(t.packageIds);
        return keccak256(
            abi.encode(
                DEAL_TERMS_TYPEHASH,
                t.holder,
                t.controller,
                t.provider,
                t.token,
                t.principal,
                t.fiatDuration,
                t.releaseDuration,
                t.disputeDuration,
                t.arbitrationDuration,
                t.fiatCommit,
                keccak256(abi.encodePacked(t.packageIds))
            )
        );
    }

    function _assertPackageIdsCanonical(bytes32[] memory ids) private pure {
        for (uint256 i = 1; i < ids.length; i++) {
            if (ids[i] <= ids[i - 1]) revert UnsortedPackageIds();
        }
    }
}
