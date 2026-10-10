// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";

/// @dev The shared bundle verifier, mocked for the tests that are about the MODULES rather than
///      about the proof: `verify` believes whatever the blob says (`abi.encode(bool)`) and leaves the
///      same content-keyed transient ticket the real one does. The caveat of every verifier mock
///      applies and is worth repeating: a mock is not a proof, and no wiring of the private layer
///      ships with one — the real adapter is exercised against the committed `prepare_side` fixture
///      in `BundleVerifier.t.sol` and `PrepareRealProof.t.sol`.
contract BundleVerifierMock is IBundleVerifier {
    /// @dev What `wasProven` answers. True by default: a suite that drives the modules directly is
    ///      asking what they do with a side that WAS proven, and making every test mint a ticket
    ///      first would only be ceremony. `setAnswer(false)` is how a test says "nobody proved this".
    bool public answer = true;

    function setAnswer(bool a) external {
        answer = a;
    }

    function verify(BundleInputs calldata, bytes calldata proof) external view returns (bool) {
        return abi.decode(proof, (bool));
    }

    function wasProven(BundleInputs calldata) external view returns (bool) {
        return answer;
    }

    /// @dev What `wasVouched` answers, apart from `answer`: a pool suite asks about the Provider's side and the
    ///      voucher's separately.
    bool public vouchAnswer = true;

    function setVouchAnswer(bool a) external {
        vouchAnswer = a;
    }

    function verifyVouch(VouchInputs calldata, bytes calldata proof) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }

    function wasVouched(VouchInputs calldata) external view returns (bool) {
        return vouchAnswer;
    }
}
