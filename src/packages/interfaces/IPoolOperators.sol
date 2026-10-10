// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev What a pool says about who acts for it (Anexo R, 2026-10-05): the operator tag each of its Controllers
///      registered, `H(sk_id, pool)` of the verified account behind it. The private passport compares it with the
///      tag the Controller's vouch proves, so the human acting for the pool is the one the pool named.
interface IPoolOperators {
    function operatorTagOf(address operator) external view returns (bytes32);
}
