// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Selectors confirmed against the mainnet Intake 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56:
///      request(bytes32,bytes,(address,bytes4),address,uint256) = 0x380c2cda, priceOf(bytes32,address) = 0x51102885.
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

/// @notice The IdentityMD Oracle attestation exactly as the live service signs and the Intake forwards it.
/// @dev Primary type `OracleAttestation` with these fifteen fields in this order; see docs/ORACLE.md.
///      `requestId` is the oracle's own request id (a UUID left-aligned in bytes32), not the Intake's request id.
///      `agreed` is the number of panel members who gave the signed answer. `figure` is 0 for bool answers.
struct Attestation {
    bytes32 requestId;
    uint256 chainId;
    bytes32 questionHash;
    uint8 answerType;
    bytes answer;
    uint256 figure;
    uint64 fromBlock;
    uint64 toBlock;
    bytes32 blockHash;
    bytes32 panelJobId;
    uint16 panelSize;
    uint16 quorum;
    uint16 agreed;
    uint64 issuedAt;
    uint64 expiresAt;
}
