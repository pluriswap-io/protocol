// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoseidonTree, DEFAULT_ROOT_HISTORY} from "../src/packages/PoseidonTree.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
import {HumanityVerifierMock} from "../mocks/HumanityVerifierMock.sol";
import {AccountVerifierMock} from "../mocks/AccountVerifierMock.sol";
import {BundleVerifierMock} from "../mocks/BundleVerifierMock.sol";
import {ClaimVerifierMock} from "../mocks/ClaimVerifierMock.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {PoseidonSingletons} from "./PoseidonSingletons.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title An official deal moves at least one lot
/// @notice PROTOCOLO.md Anexo R, 2026-09-28: the official reputation module refuses a deal under `UNIT` (250 whole
///         tokens, the unit the score buys tiers in). The kernel does not: the size of a deal is the parties', and
///         Core settles any amount. The minimum is the module's, counted in lots so it reads the same in any token.
contract MinimumPrincipalTest is Test {
    uint256 internal constant LOT = 250e6; // 250 whole tokens of a 6-decimals token
    bytes32 internal constant DEAL = keccak256("deal");

    TestToken internal token;
    PoseidonTree internal tree;
    PrivateReputation internal reputation;

    function setUp() public {
        PoseidonSingletons.install();
        token = new TestToken();
        BundleVerifierMock bundle = new BundleVerifierMock();
        HumanityVerifierMock humanity = new HumanityVerifierMock();
        AccountVerifierMock account = new AccountVerifierMock();
        ClaimVerifierMock claim = new ClaimVerifierMock();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        tree = new PoseidonTree(32, DEFAULT_ROOT_HISTORY, predicted);
        PrivatePassport passport = new PrivatePassport(tree, humanity, bundle, address(0));
        reputation = new PrivateReputation(
            passport, tree, account, bundle, claim, address(0xFEE), 0, 0, 0, 0, address(this), address(0), 1, address(0)
        );
        assertEq(address(reputation), predicted);
    }

    function _data(uint256 principal) internal view returns (bytes memory) {
        return abi.encode(
            IBundleVerifier.BundleInputs({
                dealSubject: bytes32(uint256(0x51)),
                dealId: DEAL,
                token: address(token),
                principal: principal,
                repRoot: tree.root(),
                newLeaf: bytes32(uint256(0x61)),
                nullRep: keccak256(abi.encode("null", principal)),
                pairTag: keccak256("pair"),
                lockCommit: bytes32(0),
                lockAmount: 0,
                changeNote: bytes32(0),
                nullBond: bytes32(0),
                bondRoot: bytes32(0),
                registryId: bytes32(0),
                hintS: bytes32(0),
                hintK: bytes32(0),
                arbiters: [bytes32(0), bytes32(0), bytes32(0)],
                verified: true
            }),
            abi.encode(true)
        );
    }

    function test_belowOneLot_isRefused() public {
        bytes memory data = _data(LOT - 1);
        vm.expectRevert(PrivateReputation.BelowMinimum.selector);
        reputation.admit(address(0xA11CE), DEAL, address(token), LOT - 1, address(0), data);
    }

    function test_oneLot_isAdmitted() public {
        bytes memory data = _data(LOT);
        reputation.admit(address(0xA11CE), DEAL, address(token), LOT, address(0), data);
        assertTrue(tree.isSpent(keccak256(abi.encode("null", LOT))));
    }

    /// The scale belongs to the token: 250 whole tokens of an 18-decimals token is 250e18, not 250e6.
    function test_theLotIsInWholeTokens() public {
        TestToken18 t18 = new TestToken18();
        bytes memory data = abi.encode(
            IBundleVerifier.BundleInputs({
                dealSubject: bytes32(uint256(0x51)),
                dealId: DEAL,
                token: address(t18),
                principal: 250e6,
                repRoot: tree.root(),
                newLeaf: bytes32(uint256(0x61)),
                nullRep: keccak256("null-18"),
                pairTag: keccak256("pair"),
                lockCommit: bytes32(0),
                lockAmount: 0,
                changeNote: bytes32(0),
                nullBond: bytes32(0),
                bondRoot: bytes32(0),
                registryId: bytes32(0),
                hintS: bytes32(0),
                hintK: bytes32(0),
                arbiters: [bytes32(0), bytes32(0), bytes32(0)],
                verified: true
            }),
            abi.encode(true)
        );
        vm.expectRevert(PrivateReputation.BelowMinimum.selector);
        reputation.admit(address(0xA11CE), DEAL, address(t18), 250e6, address(0), data);
    }
}

/// @dev OZ's default: 18 decimals.
contract TestToken18 is ERC20 {
    constructor() ERC20("Test 18", "T18") {}
}
