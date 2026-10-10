// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DealTerms} from "../../libraries/Types.sol";

/// @dev Kernel verbs `openCourt` / `readRuling`. 0=none, 1=holder, 2=provider, 3=stalemate.
///      `packageBinding` is the policy the kernel hashes with `PackageId.arbitration`.
interface ICourt {
    function packageId() external view returns (bytes32);
    function packageBinding() external view returns (address partner, uint256 key);
    /// @dev Flat, in the deal token, from the opener's wallet, once per deal (PROTOCOLO.md §E.3.14.6).
    ///      A deal that carries a tribunal must cost something to fight in even without a reputation
    ///      package: otherwise freezing is free for whoever can freeze. Both getters enter the
    ///      `packageId`, so a different price is a different package and the parties signed it.
    function contestFee() external view returns (uint256);
    function feeRecipient() external view returns (address);
    /// @dev The court's availability share of the principal, pulled from the Holder at activation and handed to
    ///      the court (Anexo R, 2026-09-28). Inside the `packageId`. Zero for a court paid only when it rules.
    function activationBps() external view returns (uint256);
    /// @dev The court's share of a bond lock (Anexo R, 2026-10-05), inside the `packageId`. On a ruling the kernel
    ///      leaves this share of the LOSER's lock in the vault for the court to `collect`; when the parties agree
    ///      while the court is open, or the court refuses, each side leaves half of it out of its own lock. Zero
    ///      for a court that is not paid out of the bonds.
    function bondShareBps() external view returns (uint256);
    /// @dev Kernel-only, inside `activate`: the deal, its terms, the availability fee already transferred to the
    ///      court, and the court's opaque package data. A court that cannot take the deal reverts, and the
    ///      activation with it — which is how a panel is fixed before the principal is in custody.
    ///      The sides' own package data comes too, so a court can read what each side proved about itself —
    ///      a panel, that neither party is one of its arbiters (Anexo R, 2026-09-29).
    function bind(
        bytes32 dealId,
        DealTerms calldata terms,
        uint256 activationFee,
        bytes calldata data,
        bytes calldata holderData,
        bytes calldata providerData
    ) external;
    /// @dev Whether this court can take `dealId` if its Controller escalates now. The kernel asks at the
    ///      dispute timeout (PROTOCOLO.md Anexo R, 2026-09-29): abandonment is imputed only to whoever COULD
    ///      escalate, so a court that answers false -- or does not answer -- sends the deal down the
    ///      no-tribunal branch instead of handing the principal to the Provider.
    function available(bytes32 dealId) external view returns (bool);
    function openCourt(bytes32 dealId, address controller) external payable;
    function readRuling(bytes32 dealId) external view returns (uint8);
}
