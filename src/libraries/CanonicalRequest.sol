// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice The IdentityMD Oracle's `questionHash`: keccak256 of the request's semantic fields serialised as
///         JSON with keys sorted, no whitespace, raw UTF-8, and the window resolved to blocks.
/// @dev Reproduced from two live attestations (docs/ORACLE.md). The hashed object is
///      {"answerType","chainId","definitions","evidence","question","v","window":{"fromBlock","toBlock"}};
///      panelSize, quorum, validForSeconds and consumer are not part of it. `definitions` is omitted by the
///      service only when the request declared none; this project always declares them.
library CanonicalRequest {
    using Strings for uint256;

    function hash(bytes memory escapedQuestion, string memory definitions, uint64 fromBlock, uint64 toBlock)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                '{"answerType":"bool","chainId":1,"definitions":{',
                definitions,
                '},"evidence":"panel","question":"',
                escapedQuestion,
                '","v":1,"window":{"fromBlock":',
                uint256(fromBlock).toString(),
                ',"toBlock":',
                uint256(toBlock).toString(),
                "}}"
            )
        );
    }
}
