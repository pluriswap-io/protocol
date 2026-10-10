// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pool} from "./Pool.sol";

/// @dev Neutral tooling (Anexo R, 2026-09-20): anyone creates a pool, nobody chooses which pools exist. What the
///      factory does vouch for is narrow and checkable: a pool it made points at the one escrow it names. The
///      codehash alone vouched for nothing — any clone of the implementation, made anywhere, has it, and can be
///      initialized against an escrow of its maker's choosing (evaluation of 2026-09-28).
contract PoolFactory {
    event PoolCreated(address indexed pool, address token, address escrow, bool openDeposits);

    error ZeroEscrow();

    address public immutable implementation;
    bytes32 public immutable officialCodehash;
    address public immutable escrow;
    mapping(address pool => bool) public created;

    constructor(address escrow_) {
        if (escrow_ == address(0)) revert ZeroEscrow();
        escrow = escrow_;
        implementation = address(new Pool());
        officialCodehash = keccak256(
            abi.encodePacked(hex"363d3d373d3d3d363d73", bytes20(implementation), hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    function createPool(
        address[] calldata sponsors,
        address token,
        address[] calldata controllers,
        bool openDeposits,
        address[] calldata depositors,
        uint16 controllerFeeBps
    ) external returns (address pool) {
        pool = Clones.clone(implementation);
        Pool(pool).initialize(sponsors, token, escrow, controllers, openDeposits, depositors, controllerFeeBps);
        created[pool] = true;
        emit PoolCreated(pool, token, escrow, openDeposits);
    }

    /// @notice A pool this factory made: the official code, pointed at the official escrow.
    function isOfficial(address pool) external view returns (bool) {
        return created[pool] && pool.codehash == officialCodehash;
    }
}
