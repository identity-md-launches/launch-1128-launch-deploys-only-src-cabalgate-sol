// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Attestation} from "../interfaces/IIntake.sol";

/// @notice EIP-712 digest of an IdentityMD Oracle attestation.
/// @dev Domain: name "IdentityMD Oracle", version "2", chainId and verifyingContract are the `consumer` the
///      request body declares. Type string copied from the live service's published typed data.
library OracleSignature {
    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function digest(Attestation calldata a, uint256 consumerChainId, address verifier) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), consumerChainId, verifier)
        );
        bytes32 data = keccak256(
            abi.encode(
                TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, data));
    }
}
