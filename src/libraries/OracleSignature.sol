// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Attestation} from "../interfaces/IIntake.sol";

library OracleSignature {
    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreementBps,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function digest(Attestation calldata a, address verifier) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), uint256(1), verifier)
        );
        bytes32 data = keccak256(
            abi.encode(
                TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreementBps,
                a.issuedAt,
                a.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, data));
    }
}
