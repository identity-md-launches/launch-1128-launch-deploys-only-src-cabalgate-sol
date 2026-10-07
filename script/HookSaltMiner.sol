// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Offline CREATE2 salt search. The deployer and constructor arguments must be final first.
/// @dev Contains no broadcasts, environment reads, or wallet management.
library HookSaltMiner {
    error NoSaltFound();

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (HookFlags.matches(predicted, HookFlags.CABAL)) return (salt, predicted);
        }
        revert NoSaltFound();
    }
}
