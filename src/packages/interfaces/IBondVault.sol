// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPassport} from "./IPassport.sol";

/// @dev Kernel verbs `reserve` / `unlock` / `slash` / `burn`. Deposit/withdraw are the subject's.
interface IBondVault {
    function packageId() external view returns (bytes32);
    function passport() external view returns (IPassport);
    function sink() external view returns (address);
    function available(bytes32 subject, address token) external view returns (uint256);
    function locked(bytes32 subject, address token) external view returns (uint256);
    /// @dev `data` is the side's opaque package data, forwarded by the kernel from the activation.
    function reserve(bytes32 subject, address token, bytes32 dealId, uint256 principal, bytes calldata data) external;
    function unlock(bytes32 subject, address token, bytes32 dealId) external;
    /// @dev Loser's lock to `to` (the winner's signing address), minus `feeBps` of it left for `feeTo` to
    ///      `collect` (the court, Anexo R, 2026-10-05; zero `feeTo` leaves nothing); winner's lock released.
    function slash(
        bytes32 loser,
        bytes32 winner,
        address token,
        bytes32 dealId,
        address to,
        address feeTo,
        uint256 feeBps
    ) external;
    /// @dev Both locks released, each minus `feeBps / 2` of it left for `feeTo` to `collect`: the parties agreed
    ///      while the court was open, or the court refused to decide. Zero `feeTo` is a plain unlock of both.
    function share(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId, address feeTo, uint256 feeBps)
        external;
    /// @dev What a deal left for its court: recipient, token, amount (zero once collected).
    function shareOf(bytes32 dealId) external view returns (address to, address token, uint256 amount);
    /// @dev Pays a deal's share to its recipient, who alone may call it, and returns the amount.
    function collect(bytes32 dealId) external returns (uint256 amount);
    function burn(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId) external;
}
