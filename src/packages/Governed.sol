// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Governed
/// @notice What the DAO may do to an official package (PROTOCOLO.md §3.9, Anexo R 2026-10-06): propose a new policy for
///         the deals to come, inside the bounds the package fixes in code, and wait. After `GOVERNANCE_DELAY` anyone
///         enacts it; until then the governor may withdraw it. Nothing else: no pause, no asset, no live deal.
/// @dev A live deal never sees a change. The kernel copies every price it charges at activation and never asks the
///      package again (`Deal.prices`), and a package of ours copies to the deal every other term that decides its
///      outcome when it binds. A policy enacted between the signatures and the activation moves the `packageId`, so the
///      signed one no longer resolves and the deal does not activate: nobody is bound to terms they did not see.
///      A zero `governor` freezes the policy for good.
abstract contract Governed {
    /// @dev Longer than any exit a governed package allows (21 days for an arbiter's bond), so whoever disagrees with
    ///      a proposal is out before it applies.
    uint64 public constant GOVERNANCE_DELAY = 30 days;

    /// @dev The DAO's governor: the only address that proposes or withdraws a policy. Zero: frozen.
    address public immutable governor;
    /// @dev When the pending policy can be enacted; zero when nothing is pending.
    uint64 public pendingAt;
    /// @dev The pending policy, ABI-encoded by the package that proposed it.
    bytes internal _pendingPolicy;

    event PolicyProposed(bytes policy, uint64 at);
    event PolicyCancelled();
    event PolicyEnacted(bytes policy);

    error NotGovernor();
    error NothingPending();
    error PolicyNotDue();
    error OutOfBounds();

    constructor(address governor_) {
        governor = governor_;
    }

    /// @notice Withdraws the pending policy.
    function cancelPolicy() external {
        _onlyGovernor();
        if (pendingAt == 0) revert NothingPending();
        delete _pendingPolicy;
        pendingAt = 0;
        emit PolicyCancelled();
    }

    /// @notice Anyone, once the delay is over: no change waits on a keeper, and none waits on the DAO twice.
    function enactPolicy() external {
        uint64 at = pendingAt;
        if (at == 0) revert NothingPending();
        if (block.timestamp < at) revert PolicyNotDue();
        bytes memory encoded = _pendingPolicy;
        delete _pendingPolicy;
        pendingAt = 0;
        _enact(encoded);
        emit PolicyEnacted(encoded);
    }

    /// @dev Called by a package's typed `proposePolicy` once it checked its bounds. A new proposal replaces the
    ///      pending one and restarts the delay.
    function _propose(bytes memory encoded) internal {
        _onlyGovernor();
        _pendingPolicy = encoded;
        uint64 at = uint64(block.timestamp) + GOVERNANCE_DELAY;
        pendingAt = at;
        emit PolicyProposed(encoded, at);
    }

    function _onlyGovernor() internal view {
        if (governor == address(0) || msg.sender != governor) revert NotGovernor();
    }

    /// @dev Installs a policy `_propose` accepted. Only ever called with bytes the package itself encoded.
    function _enact(bytes memory encoded) internal virtual;
}
