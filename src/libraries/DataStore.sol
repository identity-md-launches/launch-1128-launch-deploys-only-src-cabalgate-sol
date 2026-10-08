// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Immutable byte blobs stored as contract code (the SSTORE2 pattern), far cheaper than storage for
///         kilobyte-sized text that is written once and read once.
library DataStore {
    error WriteFailed();

    /// @dev Creation code: PUSH1 0x0b, MSIZE, DUP2, CODESIZE, SUB, DUP1, SWAP3, MSIZE, CODECOPY, RETURN; it returns
    ///      everything after itself as runtime code. The runtime starts with STOP so the blob can never execute.
    function write(bytes memory data) internal returns (address pointer) {
        bytes memory code = abi.encodePacked(hex"600b5981380380925939f3", hex"00", data);
        assembly ("memory-safe") {
            pointer := create(0, add(code, 0x20), mload(code))
        }
        if (pointer == address(0)) revert WriteFailed();
    }

    function read(address pointer) internal view returns (bytes memory data) {
        uint256 size = pointer.code.length;
        if (size == 0) return data;
        data = new bytes(size - 1);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, sub(size, 1))
        }
    }
}
