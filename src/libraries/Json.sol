// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Json {
    error InvalidUTF8();
    error TextTooLong();
    error ForbiddenCharacter();

    /// @notice Longest reason: 280 Unicode scalar values, each at most four UTF-8 bytes.
    uint256 internal constant MAX_REASON_CHARS = 280;
    uint256 internal constant MAX_REASON_BYTES = MAX_REASON_CHARS * 4;

    bytes16 private constant HEX = "0123456789abcdef";

    /// @notice Validates, counts and JSON-escapes the user's reason in a single pass over memory.
    /// @dev Accepts at most 280 scalar values of well-formed UTF-8 (overlong, surrogate, truncated and
    ///      out-of-range sequences revert). Control characters are refused because JSON serialisers disagree on
    ///      their escapes and the oracle's questionHash is computed over its own serialisation; the guillemets
    ///      « (U+00AB) and » (U+00BB) are refused because they delimit the reason in the question. `"` and `\`
    ///      are escaped with a backslash, exactly as the service serialises them. Returns the escaped bytes and
    ///      the scalar count of the original text.
    function prepareReason(bytes memory reason) internal pure returns (bytes memory escaped, uint256 count) {
        uint256 len = reason.length;
        if (len > MAX_REASON_BYTES) revert TextTooLong();
        escaped = new bytes(len * 2);
        // `src` walks the input, `dst` the output; both stay inside their allocations (the output is twice the
        // input, and a byte grows by at most one escaping backslash).
        uint256 src;
        uint256 end;
        uint256 dst;
        assembly ("memory-safe") {
            src := add(reason, 0x20)
            end := add(src, len)
            dst := add(escaped, 0x20)
        }
        while (src < end) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(src)
            }
            uint256 c = word >> 248;
            uint256 n;
            if (c < 0x80) {
                if (c < 0x20) revert ForbiddenCharacter();
                if (c == 0x22 || c == 0x5c) {
                    assembly ("memory-safe") {
                        mstore8(dst, 0x5c)
                        dst := add(dst, 1)
                    }
                }
                n = 1;
            } else {
                if (c >= 0xc2 && c <= 0xdf) n = 2;
                else if (c >= 0xe0 && c <= 0xef) n = 3;
                else if (c >= 0xf0 && c <= 0xf4) n = 4;
                else revert InvalidUTF8();
                if (src + n > end) revert InvalidUTF8();
                uint256 d = (word >> 240) & 0xff;
                if (d < 0x80 || d > 0xbf) revert InvalidUTF8();
                if (n == 2) {
                    if (c == 0xc2 && (d == 0xab || d == 0xbb)) revert ForbiddenCharacter();
                } else {
                    if (
                        (c == 0xe0 && d < 0xa0) || (c == 0xed && d >= 0xa0) || (c == 0xf0 && d < 0x90)
                            || (c == 0xf4 && d >= 0x90)
                    ) revert InvalidUTF8();
                    d = (word >> 232) & 0xff;
                    if (d < 0x80 || d > 0xbf) revert InvalidUTF8();
                    if (n == 4) {
                        d = (word >> 224) & 0xff;
                        if (d < 0x80 || d > 0xbf) revert InvalidUTF8();
                    }
                }
            }
            assembly ("memory-safe") {
                mcopy(dst, src, n)
                dst := add(dst, n)
                src := add(src, n)
            }
            ++count;
        }
        if (count > MAX_REASON_CHARS) revert TextTooLong();
        assembly ("memory-safe") {
            mstore(escaped, sub(dst, add(escaped, 0x20)))
        }
    }

    /// @notice Counts Unicode scalar values, rejecting malformed/overlong UTF-8 and surrogate encodings.
    /// @dev Reference implementation over arbitrary text; the gate's hot path uses prepareReason instead.
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

    /// @dev Returns the escaped contents of a JSON string, without surrounding quotes: `"` and `\` with a
    ///      backslash, control characters as \u00XX. Reference implementation over arbitrary text (the live
    ///      vector test reproduces the service's hash with it); the gate's hot path uses prepareReason.
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
        assembly ("memory-safe") {
            mstore(out, k)
        }
        return string(out);
    }
}
