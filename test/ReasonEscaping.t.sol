// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QuestionBuilder} from "src/QuestionBuilder.sol";
import {Json} from "src/libraries/Json.sol";

/// @dev Exposes the library so a revert can be caught and the single-pass fast path compared with the two
///      reference functions the library keeps beside it.
contract JsonHarness {
    function prepare(bytes calldata reason) external pure returns (bytes memory escaped, uint256 count) {
        return Json.prepareReason(reason);
    }

    function referenceLength(bytes calldata text) external pure returns (uint256) {
        return Json.length(text);
    }

    function referenceEscape(string calldata text) external pure returns (string memory) {
        return Json.escape(text);
    }

    /// @dev A lead byte as the very last byte of a 32-byte reason whose memory is followed by valid continuation
    ///      bytes. The fast path reads a whole word at a time, so only its bounds check stands between this input
    ///      and a truncated sequence being accepted because the bytes after the buffer happened to complete it.
    function truncatedLeadFollowedInMemoryByContinuationBytes()
        external
        pure
        returns (bytes memory escaped, uint256 count)
    {
        bytes memory buffer = new bytes(64);
        for (uint256 i; i < 31; ++i) {
            buffer[i] = "a";
        }
        buffer[31] = 0xe2;
        for (uint256 i = 32; i < 64; ++i) {
            buffer[i] = 0x82;
        }
        bytes memory reason = buffer;
        assembly ("memory-safe") {
            mstore(reason, 32)
        }
        return Json.prepareReason(reason);
    }
}

/// @notice The revision replaced a validate-then-escape pair with one assembly pass over the reason. These tests
///         hold that pass to an independent UTF-8 decoder and to a JSON parser that never saw the implementation.
contract ReasonEscapingTest is Test {
    uint256 private constant MAX_CHARS = 280;
    uint256 private constant MAX_BYTES = 1120;

    JsonHarness private json;
    QuestionBuilder private builder;

    function setUp() public {
        json = new JsonHarness();
        builder = new QuestionBuilder();
    }

    /// @dev Text of every UTF-8 width, with quotes and backslashes mixed in, is counted in scalar values, escaped
    ///      only at `"` and `\`, agrees with the library's reference functions and is read back byte for byte by
    ///      an independent JSON parser between exactly one pair of guillemets.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_wellFormedTextOfEveryWidthIsCountedEscapedAndQuotedExactly(bytes32 seed, uint16 countSeed)
        public
        view
    {
        uint256 n = bound(countSeed, 0, MAX_CHARS);
        (bytes memory reason, bytes memory expectedEscaped) = _generate(seed, n);
        (bytes memory escaped, uint256 count) = json.prepare(reason);
        assertEq(count, n, "scalar count");
        assertEq(escaped, expectedEscaped, "escaped bytes");
        assertEq(json.referenceLength(reason), n, "reference decoder disagrees on the count");
        assertEq(bytes(json.referenceEscape(string(reason))), escaped, "reference escaper disagrees");
        (bytes memory body,) = builder.build(_context(), string(reason));
        bytes memory question = bytes(vm.parseJsonString(string(body), ".question"));
        assertTrue(
            _contains(question, bytes.concat(bytes(unicode"Reason: «"), reason, bytes(unicode"». The reason is"))),
            "parser does not read the reason back byte for byte"
        );
        assertEq(_count(question, bytes(unicode"«")), 1);
        assertEq(_count(question, bytes(unicode"»")), 1);
    }

    /// @dev Arbitrary bytes are accepted exactly when an independent decoder accepts them, with the same error
    ///      class otherwise, and the accepted ones escape identically.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_arbitraryBytesAreJudgedLikeAnIndependentDecoder(bytes memory raw) public view {
        _compare(raw);
    }

    /// @dev One corrupted byte inside otherwise well-formed text: random bytes rarely form multibyte sequences, so
    ///      this is where truncation, stray continuation bytes, overlong forms and surrogates actually appear.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_oneCorruptedByteIsJudgedLikeAnIndependentDecoder(
        bytes32 seed,
        uint16 countSeed,
        uint16 positionSeed,
        uint8 value
    ) public view {
        uint256 n = bound(countSeed, 1, MAX_CHARS);
        (bytes memory reason,) = _generate(seed, n);
        reason[bound(positionSeed, 0, reason.length - 1)] = bytes1(value);
        _compare(reason);
    }

    /// @dev The byte bound is checked before any content (a 1121-byte reason is "too long", not "invalid"), the
    ///      scalar bound after the walk, and 280 four-byte scalars fill the byte bound exactly.
    function test_byteBoundBeforeContentAndScalarBoundAfterIt() public {
        bytes memory text = new bytes(MAX_BYTES + 1);
        for (uint256 i; i < text.length; ++i) {
            text[i] = 0xff;
        }
        vm.expectRevert(Json.TextTooLong.selector);
        json.prepare(text);
        text = new bytes(MAX_BYTES);
        for (uint256 i; i < text.length; ++i) {
            text[i] = "a";
        }
        vm.expectRevert(Json.TextTooLong.selector);
        json.prepare(text);
        text = new bytes(MAX_CHARS + 1);
        for (uint256 i; i < text.length; ++i) {
            text[i] = "a";
        }
        vm.expectRevert(Json.TextTooLong.selector);
        json.prepare(text);
        text = new bytes(MAX_CHARS);
        for (uint256 i; i < text.length; ++i) {
            text[i] = "a";
        }
        (, uint256 count) = json.prepare(text);
        assertEq(count, MAX_CHARS);
        text = new bytes(MAX_BYTES);
        for (uint256 i; i < MAX_CHARS; ++i) {
            text[4 * i] = 0xf0;
            text[4 * i + 1] = 0x9f;
            text[4 * i + 2] = 0x98;
            text[4 * i + 3] = 0x80;
        }
        (bytes memory escaped, uint256 scalars) = json.prepare(text);
        assertEq(scalars, MAX_CHARS);
        assertEq(escaped, text);
        // A control character past the 280th scalar is reported as such: the walk runs before the scalar bound.
        text = new bytes(MAX_CHARS + 2);
        for (uint256 i; i < text.length; ++i) {
            text[i] = "a";
        }
        text[MAX_CHARS + 1] = 0x0a;
        vm.expectRevert(Json.ForbiddenCharacter.selector);
        json.prepare(text);
    }

    function test_quotesAndBackslashesAreEscapedBetweenMultibyteText() public view {
        (bytes memory escaped, uint256 count) = json.prepare(bytes(unicode'é"🐉\\x'));
        assertEq(escaped, bytes(unicode'é\\"🐉\\\\x'));
        assertEq(count, 5);
        (escaped, count) = json.prepare(bytes('""\\\\'));
        assertEq(escaped, bytes('\\"\\"\\\\\\\\'));
        assertEq(count, 4);
        (escaped, count) = json.prepare("");
        assertEq(escaped.length, 0);
        assertEq(count, 0);
    }

    function test_truncatedLeadByteAtTheEndIsRefusedWhateverFollowsInMemory() public {
        vm.expectRevert(Json.InvalidUTF8.selector);
        json.truncatedLeadFollowedInMemoryByContinuationBytes();
    }

    /// @dev The question keeps the reason's bytes raw: the gate's bound counts scalars of the whole question, so a
    ///      reason of 280 four-byte scalars beside the widest sell numbers must still fit, and does (see
    ///      QuestionProperties); here the same reason must produce a question whose escaped form the builder's
    ///      own hash function and an independent canonicalisation agree on.
    function test_escapedQuestionHashesLikeTheParsedBody() public view {
        (bytes memory reason,) = _generate(keccak256("hash vector"), MAX_CHARS);
        (bytes memory body, bytes memory escaped) = builder.build(_context(), string(reason));
        string memory question = vm.parseJsonString(string(body), ".question");
        assertEq(bytes(_jsonEscape(bytes(question))), escaped);
        bytes32 expected = keccak256(
            abi.encodePacked(
                '{"answerType":"bool","chainId":1,"definitions":{"amount":"',
                _jsonEscape(bytes(vm.parseJsonString(string(body), ".definitions.amount"))),
                '","costBasis":"',
                _jsonEscape(bytes(vm.parseJsonString(string(body), ".definitions.costBasis"))),
                '","impact":"',
                _jsonEscape(bytes(vm.parseJsonString(string(body), ".definitions.impact"))),
                '","reason":"',
                _jsonEscape(bytes(vm.parseJsonString(string(body), ".definitions.reason"))),
                '"},"evidence":"panel","question":"',
                _jsonEscape(bytes(question)),
                '","v":1,"window":{"fromBlock":7,"toBlock":9}}'
            )
        );
        assertEq(builder.questionHash(escaped, 7, 9), expected);
    }

    function _compare(bytes memory raw) private view {
        (bytes4 expectedError, bytes memory expectedEscaped, uint256 expectedCount) = _independent(raw);
        try json.prepare(raw) returns (bytes memory escaped, uint256 count) {
            assertEq(bytes32(expectedError), bytes32(0), "fast path accepted text the independent decoder refuses");
            assertEq(escaped, expectedEscaped, "escaped bytes differ from the independent escaper");
            assertEq(count, expectedCount, "scalar count differs from the independent decoder");
        } catch (bytes memory revertData) {
            assertTrue(expectedError != bytes4(0), "fast path refused well-formed text");
            assertEq(
                bytes32(_selectorOf(revertData)),
                bytes32(expectedError),
                "error class differs from the independent decoder"
            );
        }
    }

    /// @dev Independent decoder: classifies lead bytes by the RFC 3629 table, decodes the code point from the
    ///      continuation bytes and judges it (overlong, surrogate, above U+10FFFF, control, guillemet), reporting
    ///      the error class the gate should raise. Zero means accepted.
    function _independent(bytes memory raw) private pure returns (bytes4 failure, bytes memory escaped, uint256 count) {
        if (raw.length > MAX_BYTES) return (Json.TextTooLong.selector, "", 0);
        escaped = new bytes(raw.length * 2);
        uint256 k;
        uint256 i;
        while (i < raw.length) {
            uint8 c = uint8(raw[i]);
            uint256 n;
            uint256 codePoint;
            if (c < 0x80) {
                if (c < 0x20) return (Json.ForbiddenCharacter.selector, "", 0);
                n = 1;
                codePoint = c;
            } else if (c >= 0xc2 && c <= 0xdf) {
                n = 2;
                codePoint = c & 0x1f;
            } else if (c >= 0xe0 && c <= 0xef) {
                n = 3;
                codePoint = c & 0x0f;
            } else if (c >= 0xf0 && c <= 0xf4) {
                n = 4;
                codePoint = c & 0x07;
            } else {
                return (Json.InvalidUTF8.selector, "", 0);
            }
            if (i + n > raw.length) return (Json.InvalidUTF8.selector, "", 0);
            for (uint256 j = 1; j < n; ++j) {
                uint8 d = uint8(raw[i + j]);
                if (d < 0x80 || d > 0xbf) return (Json.InvalidUTF8.selector, "", 0);
                codePoint = (codePoint << 6) | (d & 0x3f);
            }
            if (n == 3 && (codePoint < 0x800 || (codePoint >= 0xd800 && codePoint <= 0xdfff))) {
                return (Json.InvalidUTF8.selector, "", 0);
            }
            if (n == 4 && (codePoint < 0x10000 || codePoint > 0x10ffff)) return (Json.InvalidUTF8.selector, "", 0);
            if (codePoint == 0xab || codePoint == 0xbb) return (Json.ForbiddenCharacter.selector, "", 0);
            if (c == 0x22 || c == 0x5c) escaped[k++] = "\\";
            for (uint256 j; j < n; ++j) {
                escaped[k++] = raw[i + j];
            }
            i += n;
            ++count;
        }
        if (count > MAX_CHARS) return (Json.TextTooLong.selector, "", 0);
        assembly ("memory-safe") {
            mstore(escaped, k)
        }
    }

    /// @dev Generates `n` scalar values drawn from every width: printable ASCII with extra weight on `"` and `\`,
    ///      DEL, the two-byte range without the guillemets, the BMP without surrogates and the supplementary planes.
    function _generate(bytes32 seed, uint256 n) private pure returns (bytes memory text, bytes memory escaped) {
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 class = r % 8;
            uint256 draw = r >> 8;
            uint256 codePoint;
            if (class < 2) {
                codePoint = 0x20 + draw % 0x5f;
            } else if (class == 2) {
                codePoint = draw % 2 == 0 ? 0x22 : 0x5c;
            } else if (class == 3) {
                codePoint = draw % 3 == 0 ? 0x7f : 0x30 + draw % 10;
            } else if (class == 4) {
                codePoint = 0x80 + draw % 0x780;
                if (codePoint == 0xab || codePoint == 0xbb) codePoint = 0xac;
            } else if (class == 5) {
                codePoint = 0x800 + draw % 0xf800;
                if (codePoint >= 0xd800 && codePoint <= 0xdfff) codePoint -= 0x800;
            } else {
                codePoint = 0x10000 + draw % 0x100000;
            }
            bytes memory encoded = _utf8(codePoint);
            text = bytes.concat(text, encoded);
            escaped = bytes.concat(escaped, codePoint == 0x22 || codePoint == 0x5c ? bytes("\\") : bytes(""), encoded);
        }
    }

    function _utf8(uint256 codePoint) private pure returns (bytes memory) {
        if (codePoint < 0x80) return abi.encodePacked(uint8(codePoint));
        if (codePoint < 0x800) {
            return abi.encodePacked(uint8(0xc0 | (codePoint >> 6)), uint8(0x80 | (codePoint & 0x3f)));
        }
        if (codePoint < 0x10000) {
            return abi.encodePacked(
                uint8(0xe0 | (codePoint >> 12)),
                uint8(0x80 | ((codePoint >> 6) & 0x3f)),
                uint8(0x80 | (codePoint & 0x3f))
            );
        }
        return abi.encodePacked(
            uint8(0xf0 | (codePoint >> 18)),
            uint8(0x80 | ((codePoint >> 12) & 0x3f)),
            uint8(0x80 | ((codePoint >> 6) & 0x3f)),
            uint8(0x80 | (codePoint & 0x3f))
        );
    }

    function _jsonEscape(bytes memory input) private pure returns (string memory) {
        bytes memory out = new bytes(input.length * 2);
        uint256 k;
        for (uint256 i; i < input.length; ++i) {
            if (input[i] == '"' || input[i] == "\\") out[k++] = "\\";
            out[k++] = input[i];
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
        return string(out);
    }

    function _selectorOf(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 32))
        }
    }

    function _context() private pure returns (QuestionBuilder.Context memory c) {
        c.buy = false;
        c.user = address(0xA11CE);
        c.amount = 7 ether;
        c.impactBps = 49;
        c.maxAmount = 10000 ether;
        c.maxImpactBps = 500;
        c.holdings = 8 ether;
        c.currentPrice = 1 ether;
        c.averageBuyPrice = 2 ether;
        c.firstBuy = 1_800_000_000;
        c.timeHeld = 3600;
        c.trackedUnits = 7 ether;
        c.windowHours = 1;
        c.panelSize = 30;
        c.quorum = 20;
        c.verifier = address(0xBEEF);
        c.nftStatus = "unknown";
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        return _count(haystack, needle) > 0;
    }

    function _count(bytes memory haystack, bytes memory needle) private pure returns (uint256 count) {
        if (needle.length == 0 || needle.length > haystack.length) return 0;
        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool matches = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) ++count;
        }
    }
}
