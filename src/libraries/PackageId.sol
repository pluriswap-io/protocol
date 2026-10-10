// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kernel hash formula: `packageId = keccak(kind, module address, policy)`.
///      Not an allowlist. Any impl that hashes to a signed id resolves.
///      New kind = new kernel version; new impl of an existing kind = another id, same escrow.
library PackageId {
    bytes32 internal constant BONDS_KIND = keccak256("PluriSwap.Package.BONDS");
    bytes32 internal constant PASSPORT_KIND = keccak256("PluriSwap.Package.PASSPORT");
    bytes32 internal constant REPUTATION_KIND = keccak256("PluriSwap.Package.REPUTATION");
    bytes32 internal constant ARBITRATION_KIND = keccak256("PluriSwap.Package.ARBITRATION");
    bytes32 internal constant ZK_KIND = keccak256("PluriSwap.Package.ZK");
    uint16 public constant BOND_LOCK_BPS = 1000;

    function bonds(address vault, address sink) public pure returns (bytes32) {
        return keccak256(abi.encode(BONDS_KIND, vault, sink, BOND_LOCK_BPS));
    }

    function passport(address adapter) public pure returns (bytes32) {
        return keccak256(abi.encode(PASSPORT_KIND, adapter));
    }

    function reputation(
        address module,
        address feeRecipient,
        uint256 activationFee,
        uint256 completionFee,
        uint256 contestBps,
        uint256 contestFloor
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(REPUTATION_KIND, module, feeRecipient, activationFee, completionFee, contestBps, contestFloor)
        );
    }

    /// @dev `activationBps` is the court's availability share, pulled from the Holder at activation (Anexo R,
    ///      2026-09-28): a panel is paid for standing by, and that price is signed like every other.
    ///      `bondShareBps` is the court's share of the loser's bond lock (Anexo R, 2026-10-05): a panel is paid
    ///      for deciding out of the bonds, not by whoever opens it, and that price is signed too.
    function arbitration(
        address adapter,
        address tribunal,
        uint256 courtFee,
        uint256 contestFee,
        address feeRecipient,
        uint256 activationBps,
        uint256 bondShareBps
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ARBITRATION_KIND, adapter, tribunal, courtFee, contestFee, feeRecipient, activationBps, bondShareBps
            )
        );
    }

    function zk(address module, address verifier, address feeRecipient, uint256 verifyFee)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(ZK_KIND, module, verifier, feeRecipient, verifyFee));
    }
}
