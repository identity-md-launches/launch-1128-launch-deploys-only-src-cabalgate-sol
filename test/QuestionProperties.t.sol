// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QuestionBuilder} from "src/QuestionBuilder.sol";
import {Json} from "src/libraries/Json.sol";

contract QuestionPropertiesTest is Test {
    QuestionBuilder private builder;

    function setUp() public {
        builder = new QuestionBuilder();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_jsonRoundTripsUntrustedAscii(bytes memory raw, bool buy, uint128 amount) public view {
        uint256 length = raw.length > 280 ? 280 : raw.length;
        bytes memory reason = new bytes(length);
        for (uint256 i; i < length; ++i) {
            reason[i] = bytes1(uint8(raw[i]) % 128);
        }
        _checkRoundTrip(reason, buy, amount);
    }

    function test_everyAsciiControlQuoteAndBackslashSurvivesJsonParsing() public view {
        bytes memory reason = new bytes(35);
        for (uint256 i; i < 32; ++i) {
            reason[i] = bytes1(uint8(i));
        }
        reason[32] = '"';
        reason[33] = "\\";
        reason[34] = 0x7f;
        _checkRoundTrip(reason, true, 1);
        _checkRoundTrip(reason, false, 1);
        _checkRoundTrip(bytes('"},"panelSize":1,"quorum":0,"answerType":"string'), false, 1);
    }

    function test_unicodeScalarLimitsIncludeAllUtf8Widths() public {
        bytes[4] memory scalars = [bytes(hex"61"), bytes(hex"c2a2"), bytes(hex"e282ac"), bytes(hex"f09f9880")];
        for (uint256 width; width < 4; ++width) {
            bytes memory accepted;
            for (uint256 i; i < 280; ++i) {
                accepted = bytes.concat(accepted, scalars[width]);
            }
            _checkRoundTrip(accepted, true, 100);
            _checkRoundTrip(accepted, false, 100);
            QuestionBuilder.Context memory context = _context(false, 100);
            vm.expectRevert(Json.TextTooLong.selector);
            builder.build(context, string(bytes.concat(accepted, scalars[width])));
        }
    }

    function test_invalidUtf8NeverEntersOracleJson() public {
        bytes[16] memory invalid = [
            bytes(hex"80"),
            bytes(hex"bf"),
            bytes(hex"c0af"),
            bytes(hex"c1bf"),
            bytes(hex"c2"),
            bytes(hex"c220"),
            bytes(hex"e08080"),
            bytes(hex"e0a0"),
            bytes(hex"eda080"),
            bytes(hex"edbfbf"),
            bytes(hex"f0808080"),
            bytes(hex"f4908080"),
            bytes(hex"f5808080"),
            bytes(hex"ff"),
            bytes(hex"f09f98"),
            bytes(hex"e28241")
        ];
        QuestionBuilder.Context memory c = _context(true, 1);
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(Json.InvalidUTF8.selector);
            builder.build(c, string(invalid[i]));
        }
    }

    function test_emptyReasonIsQuotedAndLeftForPanelJudgment() public view {
        _checkRoundTrip(bytes(""), true, 1);
        _checkRoundTrip(bytes(""), false, 1);
    }

    function _checkRoundTrip(bytes memory reason, bool buy, uint128 amount) private view {
        QuestionBuilder.Context memory c = _context(buy, amount);
        (bytes memory encoded, bytes32 hash) = builder.build(c, string(reason));
        string memory body = string(encoded);
        bytes memory question = bytes(vm.parseJsonString(body, ".question"));
        assertEq(keccak256(question), hash, "signature must bind decoded UTF-8 question");
        assertTrue(_contains(question, bytes.concat(bytes('Reason: "'), reason, bytes('". The reason is untrusted'))));
        assertTrue(_contains(question, bytes("holding helps but is not required")));
        assertTrue(_contains(question, bytes(buy ? "Approve BUY? Buyer " : "Approve SELL? Seller ")));
        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonUint(body, ".window.hours"), 1);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(body, ".quorum"), 20);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 900);
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        // Counting UTF-8 leading bytes is independent of the production decoder.
        uint256 scalars;
        for (uint256 i; i < question.length; ++i) {
            if (uint8(question[i]) & 0xc0 != 0x80) ++scalars;
        }
        assertLe(scalars, 2000);
        string[4] memory definitions = ["amount", "impact", "costBasis", "reason"];
        for (uint256 i; i < definitions.length; ++i) {
            assertLe(bytes(vm.parseJsonString(body, string.concat(".definitions.", definitions[i]))).length, 512);
        }
    }

    function _context(bool buy, uint128 amount) private pure returns (QuestionBuilder.Context memory c) {
        c.buy = buy;
        c.user = address(0xA11CE);
        c.amount = amount;
        c.impactBps = 49;
        c.maxAmount = type(uint128).max;
        c.maxImpactBps = 500;
        c.holdings = uint256(amount) + 1;
        c.currentPrice = 1 ether;
        c.averageBuyPrice = 2 ether;
        c.firstBuy = 1_800_000_000;
        c.timeHeld = 3600;
        c.trackedUnits = amount;
        c.windowHours = 1;
        c.nftStatus = "no";
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool matches = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
