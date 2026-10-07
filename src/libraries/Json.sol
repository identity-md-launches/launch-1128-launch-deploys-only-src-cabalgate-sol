// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Json {
    error InvalidUTF8();
    error TextTooLong();
    bytes16 private constant HEX = "0123456789abcdef";

    /// @notice Counts Unicode scalar values, rejecting malformed/overlong UTF-8 and surrogate encodings.
    function length(bytes memory s) internal pure returns (uint256 count) {
        uint256 i;
        while (i < s.length) {
            uint8 c = uint8(s[i]);
            uint256 n;
            if (c < 0x80) n = 1;
            else if (c >= 0xc2 && c <= 0xdf) n = 2;
            else if (c >= 0xe0 && c <= 0xef) n = 3;
            else if (c >= 0xf0 && c <= 0xf4) n = 4;
            else revert InvalidUTF8();
            if (i + n > s.length) revert InvalidUTF8();
            for (uint256 j = 1; j < n; ++j) {
                uint8 d = uint8(s[i + j]);
                if (d < 0x80 || d > 0xbf) revert InvalidUTF8();
            }
            if (n >= 3) {
                uint8 d = uint8(s[i + 1]);
                if (
                    (c == 0xe0 && d < 0xa0) || (c == 0xed && d >= 0xa0) || (c == 0xf0 && d < 0x90)
                        || (c == 0xf4 && d >= 0x90)
                ) revert InvalidUTF8();
            }
            i += n;
            ++count;
        }
    }

    function validateReason(string memory reason) internal pure {
        if (bytes(reason).length > 1120 || length(bytes(reason)) > 280) revert TextTooLong();
    }

    /// @dev Returns the escaped contents of a JSON string, without surrounding quotes.
    function escape(string memory s) internal pure returns (string memory) {
        bytes memory input = bytes(s);
        bytes memory out = new bytes(input.length * 6);
        uint256 k;
        for (uint256 i; i < input.length; ++i) {
            uint8 c = uint8(input[i]);
            if (c == 34 || c == 92) {
                out[k++] = "\\";
                out[k++] = bytes1(c);
            } else if (c < 32) {
                out[k++] = "\\";
                out[k++] = "u";
                out[k++] = "0";
                out[k++] = "0";
                out[k++] = HEX[c >> 4];
                out[k++] = HEX[c & 15];
            } else {
                out[k++] = bytes1(c);
            }
        }
        assembly ("memory-safe") { mstore(out, k) }
        return string(out);
    }
}
