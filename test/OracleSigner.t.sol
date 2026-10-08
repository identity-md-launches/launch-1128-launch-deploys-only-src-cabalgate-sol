// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CabalFixture} from "./CabalFixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Attestation} from "../src/interfaces/IIntake.sol";
import {OracleSignature} from "../src/libraries/OracleSignature.sol";

contract MockOracleRegistry {
    address private immutable key;

    constructor(address key_) {
        key = key_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == key ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract OracleSignerTest is CabalFixture {
    // Pins the audited ECDSA-only trust model: the configured signer must be the attester key.
    function test_registrySignatureIsNotAnEOASignatureForTheConfiguredSigner() public {
        MockOracleRegistry registry = new MockOracleRegistry(vm.addr(ORACLE_KEY));
        CabalGate.Config memory cfg = gate.configuration();
        cfg.signer = address(registry);
        gate.configure(cfg);
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        bytes memory signature = sign(a, ORACLE_KEY, address(gate));
        assertEq(registry.isValidSignature(this.digest(a), signature), bytes4(0x1626ba7e));
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, id, a, signature);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
    }

    function digest(Attestation calldata a) external view returns (bytes32) {
        return OracleSignature.digest(a, 1, address(gate));
    }
}
