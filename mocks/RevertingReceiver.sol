// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RevertingReceiver {
    error AlwaysReverts();

    fallback() external payable {
        revert AlwaysReverts();
    }

    receive() external payable {
        revert AlwaysReverts();
    }
}

/// @dev ERC-20 that reverts when `to` is the configured sink (blacklist / hook).
contract TokenThatRejectsReceiver is ERC20 {
    address public immutable rejected;

    constructor(address rejected_) ERC20("Reject USD", "RUSD") {
        rejected = rejected_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == rejected) revert RevertingReceiver.AlwaysReverts();
        super._update(from, to, value);
    }
}
