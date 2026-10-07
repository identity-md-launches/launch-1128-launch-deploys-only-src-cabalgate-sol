// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }
    function priceOf(bytes32 action, address paymentToken) external view returns (uint256);
    function request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        address paymentToken,
        uint256 price
    ) external returns (bytes32 requestId);
}

/// @dev Reconstructed from the truncated brief; the exact signed schema is documented in docs/ORACLE.md.
struct Attestation {
    bytes32 requestId;
    uint256 chainId;
    bytes32 questionHash;
    uint8 answerType;
    bytes answer;
    uint64 fromBlock;
    uint64 toBlock;
    bytes32 blockHash;
    bytes32 panelJobId;
    uint16 panelSize;
    uint16 quorum;
    uint16 agreementBps;
    uint64 issuedAt;
    uint64 expiresAt;
}
