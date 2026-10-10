// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PackageMods} from "../src/libraries/Types.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../mocks/Reputation.sol";
import {BondVault} from "../mocks/BondVault.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @title The bonds a panel deal carries
/// @dev Anexo R, 2026-10-05: a deal with the official panel carries both sides' bonds, because the panel is paid out
///      of them. The kernel only takes BONDS next to PASSPORT and REPUTATION, so a suite about the panel gets the
///      wallet-keyed lab trio — fee-free, ignoring each side's package data — and both sides' bonds deposited.
abstract contract PanelBonds is Test {
    PassportMock internal bondPassport;
    Reputation internal bondReputation;
    BondVault internal bondVault;

    function _deployBonds(address escrow) internal {
        bondPassport = new PassportMock();
        bondReputation = new Reputation(bondPassport, address(0xFEE), 0, 0, 0, 0, escrow);
        bondVault = new BondVault(escrow, address(0xdeaD), bondPassport);
    }

    /// @dev `wallet` becomes a subject with `amount` of bond deposited in the vault.
    function _bondSide(TestToken token, address wallet, uint256 amount) internal {
        bytes32 subject = keccak256(abi.encode("panel-bonds", wallet));
        bondPassport.setHuman(wallet, subject);
        token.mint(address(this), amount);
        token.approve(address(bondVault), amount);
        bondVault.deposit(subject, address(token), amount);
    }

    /// @dev `ids` plus the trio's three, sorted.
    function _withBondIds(bytes32[] memory ids) internal view returns (bytes32[] memory out) {
        out = new bytes32[](ids.length + 3);
        out[0] = bondPassport.packageId();
        out[1] = bondReputation.packageId();
        out[2] = bondVault.packageId();
        for (uint256 i; i < ids.length; i++) {
            out[i + 3] = ids[i];
        }
        // The kernel takes the signed ids in ascending order.
        for (uint256 i; i < out.length; i++) {
            for (uint256 j = i + 1; j < out.length; j++) {
                if (out[j] < out[i]) (out[i], out[j]) = (out[j], out[i]);
            }
        }
    }

    function _withBondMods(PackageMods memory mods) internal view returns (PackageMods memory) {
        mods.passport = address(bondPassport);
        mods.reputation = address(bondReputation);
        mods.bonds = address(bondVault);
        return mods;
    }
}
