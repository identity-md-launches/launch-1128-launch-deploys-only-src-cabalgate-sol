// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Addresses provided by the assignment, not live-chain attestations of their implementation.
library MainnetDefaults {
    address internal constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address internal constant IDENTITY_NFT = address(bytes20(hex"0000ec93127baa929e58e97dd0095a2bfb38ec1d"));
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
}
