// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library Settlement {
    using SafeERC20 for IERC20;

    error InexactPull();

    /// @dev A payout the token refused to push now waits in credit for its beneficiary to withdraw.
    event Credited(address indexed token, address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed token, address indexed beneficiary, uint256 amount);

    struct Store {
        mapping(address token => mapping(address beneficiary => uint256 amount)) credits;
    }

    function pullExact(address token, address from, uint256 principal) public {
        IERC20 t = IERC20(token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(from, address(this), principal);
        if (t.balanceOf(address(this)) - before != principal) revert InexactPull();
    }

    function creditThenTryPush(Store storage s, address token, address to, uint256 amount) public {
        s.credits[token][to] += amount;
        bool ok = IERC20(token).trySafeTransfer(to, amount);
        if (ok) s.credits[token][to] -= amount;
        else emit Credited(token, to, amount);
    }

    function creditOf(Store storage s, address token, address beneficiary) public view returns (uint256) {
        return s.credits[token][beneficiary];
    }

    function withdraw(Store storage s, address token, address beneficiary) public {
        uint256 amount = s.credits[token][beneficiary];
        if (amount == 0) return;
        IERC20(token).safeTransfer(beneficiary, amount);
        s.credits[token][beneficiary] = 0;
        emit Withdrawn(token, beneficiary, amount);
    }
}
