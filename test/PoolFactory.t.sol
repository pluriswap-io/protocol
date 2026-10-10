// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../src/pools/Pool.sol";
import {PoolFactory} from "../src/pools/PoolFactory.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {Escrow} from "../src/Escrow.sol";

contract PoolFactoryTest is Test {
    PoolFactory internal factory;
    TestToken internal token;
    Escrow internal escrow;
    address internal sponsor = address(0xA11CE);

    function setUp() public {
        token = new TestToken();
        escrow = new Escrow(address(0), 0, 0);
        factory = new PoolFactory(address(escrow));
    }

    function test_createPool_sameCodehashDifferentParams() public {
        address[] memory sponsors = new address[](1);
        sponsors[0] = sponsor;
        address[] memory a = new address[](1);
        a[0] = address(0xC0);
        address[] memory depositors = new address[](1);
        depositors[0] = sponsor;
        address[] memory none = new address[](0);

        address p1 = factory.createPool(sponsors, address(token), a, false, depositors, 0);
        address p2 = factory.createPool(sponsors, address(token), none, true, none, 100);
        assertTrue(p1 != p2);
        assertEq(p1.codehash, p2.codehash);
        assertEq(p1.codehash, factory.officialCodehash());
        assertTrue(factory.isOfficial(p1));
        assertTrue(factory.isOfficial(p2));
        assertTrue(Pool(p1).sponsors(sponsor));
        assertTrue(Pool(p1).designated(address(0xC0)));
        assertFalse(Pool(p2).designated(address(0xC0)));
        assertTrue(Pool(p2).openDeposits());
        assertEq(Pool(p2).controllerFeeBps(), 100);
    }

    function test_initialize_cannotRepeat() public {
        address[] memory sponsors = new address[](1);
        sponsors[0] = sponsor;
        address[] memory none = new address[](0);
        address[] memory depositors = new address[](1);
        depositors[0] = sponsor;
        address p = factory.createPool(sponsors, address(token), none, false, depositors, 0);
        vm.expectRevert(Pool.AlreadyInitialized.selector);
        Pool(p).initialize(sponsors, address(token), address(escrow), none, false, depositors, 0);
    }

    function test_implementation_cannotInitialize() public {
        address[] memory sponsors = new address[](1);
        sponsors[0] = sponsor;
        address[] memory none = new address[](0);
        address[] memory depositors = new address[](1);
        depositors[0] = sponsor;
        address impl = factory.implementation();
        vm.expectRevert(Pool.AlreadyInitialized.selector);
        Pool(impl).initialize(sponsors, address(token), address(escrow), none, false, depositors, 0);
    }

    function test_rawPool_isNotOfficial() public {
        assertFalse(factory.isOfficial(address(new Pool())));
    }

    function test_create_revertsEmptySponsors() public {
        address[] memory none = new address[](0);
        vm.expectRevert(Pool.EmptySponsors.selector);
        factory.createPool(none, address(token), none, true, none, 0);
    }

    function test_create_revertsOpenWithDepositors() public {
        address[] memory sponsors = new address[](1);
        sponsors[0] = sponsor;
        address[] memory none = new address[](0);
        address[] memory depositors = new address[](1);
        depositors[0] = sponsor;
        vm.expectRevert(Pool.OpenHasDepositors.selector);
        factory.createPool(sponsors, address(token), none, true, depositors, 0);
    }
}
