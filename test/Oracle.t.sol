// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {CabalFixture} from "./CabalFixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Attestation} from "../src/interfaces/IIntake.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {Json} from "../src/libraries/Json.sol";

contract OracleTest is CabalFixture {
    function test_submitPaysExactlyQuotedPriceAndRevokesAllowance() public {
        uint256 beforeBalance = imd.balanceOf(ALICE);
        intake.setPrice(7 ether);
        bytes32 id = submit(true, 100 ether);
        assertEq(imd.balanceOf(ALICE), beforeBalance - 7 ether);
        assertEq(imd.balanceOf(address(intake)), 7 ether);
        assertEq(intake.observedAllowance(), 7 ether);
        assertEq(imd.allowance(address(gate), address(intake)), 0);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.lastToken(), address(imd));
        (address target, bytes4 selector) = intake.lastCallback();
        assertEq(target, address(gate));
        assertEq(selector, gate.onOracleResult.selector);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
        assertEq(gate.activeRequest(ALICE), id);
    }

    function test_jsonEscapesReasonAndBindsDecodedQuestion() public {
        string memory reason = 'Research "CABAL"\\test\n\t\r\x00"},"panelSize":1,"x":"';
        vm.prank(ALICE);
        bytes32 id = gate.submitBuyRequest(100 ether, reason);
        string memory body = string(intake.lastBody());
        string memory question = vm.parseJsonString(body, ".question");
        assertEq(keccak256(bytes(question)), gate.getRequest(id).questionHash);
        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(body, ".quorum"), 20);
        assertEq(vm.parseJsonUint(body, ".window.hours"), 1);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 900);
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertTrue(_contains(question, string.concat('Reason: "', reason, '"')));
        assertTrue(_contains(question, "untrusted user text"));
        assertTrue(_contains(question, "helps but is not required"));
        assertLe(Json.length(bytes(question)), 2000);
        string[4] memory fields =
            [".definitions.amount", ".definitions.impact", ".definitions.costBasis", ".definitions.reason"];
        for (uint256 i; i < fields.length; ++i) {
            assertLe(Json.length(bytes(vm.parseJsonString(body, fields[i]))), 512);
        }
    }

    function test_sellQuestionIncludesHoldingsPriceBasisTimeNftAndReason() public {
        uint256 received = buy(100 ether);
        vm.warp(block.timestamp + 3600);
        vm.mockCall(gate.IDENTITY_NFT(), abi.encodeWithSignature("balanceOf(address)", ALICE), abi.encode(uint256(1)));
        submit(false, received / 2);
        string memory question = vm.parseJsonString(string(intake.lastBody()), ".question");
        assertTrue(_contains(question, "Approve SELL? Seller"));
        assertTrue(_contains(question, "share of holdings bps="));
        assertTrue(_contains(question, "indicative current price"));
        assertTrue(_contains(question, "gate-recorded average buy price"));
        assertTrue(_contains(question, "first buy timestamp="));
        assertTrue(_contains(question, "time held seconds=3600"));
        assertTrue(_contains(question, "holding=yes"));
        assertTrue(_contains(question, "untrusted user text"));
    }

    function test_280UnicodeCharactersAccepted281Rejected() public {
        bytes memory reason = new bytes(280 * 4);
        for (uint256 i; i < 280; ++i) {
            reason[4 * i] = 0xf0;
            reason[4 * i + 1] = 0x9f;
            reason[4 * i + 2] = 0x98;
            reason[4 * i + 3] = 0x80;
        }
        vm.prank(ALICE);
        gate.submitBuyRequest(100 ether, string(reason));
        vm.prank(BOB);
        vm.expectRevert(Json.TextTooLong.selector);
        gate.submitBuyRequest(100 ether, string(abi.encodePacked(reason, "a")));
    }

    function test_malformedUTF8Rejected() public {
        vm.prank(ALICE);
        vm.expectRevert(Json.InvalidUTF8.selector);
        gate.submitBuyRequest(100 ether, string(abi.encodePacked(hex"c080")));
        vm.prank(ALICE);
        vm.expectRevert(Json.InvalidUTF8.selector);
        gate.submitBuyRequest(100 ether, string(abi.encodePacked(hex"eda080")));
    }

    function test_trueApprovesForFiveMinutesAndFalseRejects() public {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(intake)));
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
        assertEq(gate.getRequest(id).approvedUntil, block.timestamp + 300);
        vm.prank(BOB);
        bytes32 other = gate.submitBuyRequest(100 ether, "Fund a concrete October event");
        a = attestation(other, false);
        intake.deliver(gate, other, a, sign(a, ORACLE_KEY, address(intake)));
        assertEq(uint8(gate.getRequest(other).status), uint8(CabalGate.Status.Rejected));
        assertEq(gate.activeRequest(BOB), bytes32(0));
    }

    function test_approvalNeverOutlivesAttestation() public {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        a.expiresAt = uint64(block.timestamp + 100);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(intake)));
        assertEq(gate.getRequest(id).approvedUntil, a.expiresAt);
    }

    function test_onlyIntakeOnlyPendingReplayAndUnknownIds() public {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        bytes memory sig = sign(a, ORACLE_KEY, address(intake));
        vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
        gate.onOracleResult(id, a, sig);
        vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
        intake.deliver(gate, bytes32(uint256(900)), a, sig);
        intake.deliver(gate, id, a, sig);
        vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
        intake.deliver(gate, id, a, sig);
    }

    function test_badSignerDomainAndTampering() public {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        bytes memory sig = sign(a, ORACLE_KEY + 1, address(intake));
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, id, a, sig);
        sig = sign(a, ORACLE_KEY, address(gate));
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, id, a, sig);
        sig = sign(a, ORACLE_KEY, address(intake));
        a.answer = abi.encode(false);
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, id, a, sig);
    }

    function testFuzz_attestationFieldsAreBound(uint8 field) public {
        field = uint8(bound(field, 0, 16));
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        if (field == 0) a.requestId = bytes32(uint256(99));
        if (field == 1) a.chainId = 10;
        if (field == 2) a.questionHash = keccak256("another question");
        if (field == 3) a.answerType = 9;
        if (field == 4) a.answer = hex"01";
        if (field == 5) a.answer = abi.encode(uint256(2));
        if (field == 6) a.fromBlock = a.toBlock + 1;
        if (field == 7) a.toBlock = uint64(block.number + 1);
        if (field == 8) a.blockHash = 0;
        if (field == 9) a.panelJobId = 0;
        if (field == 10) a.panelSize = 29;
        if (field == 11) a.quorum = 19;
        if (field == 12) a.agreementBps = 6666;
        if (field == 13) a.agreementBps = 10001;
        if (field == 14) a.issuedAt = uint64(block.timestamp + 1);
        if (field == 15) a.expiresAt = uint64(block.timestamp);
        if (field == 16) a.expiresAt = uint64(block.timestamp + 901);
        bytes memory sig = sign(a, ORACLE_KEY, address(intake));
        vm.expectRevert();
        intake.deliver(gate, id, a, sig);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
    }

    function test_timeoutClearsNoLateCallbackNoTradeFundsEscrowed() public {
        uint256 balance = imd.balanceOf(ALICE);
        bytes32 id = submit(true, 100 ether);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.clearRequest(id);
        vm.warp(block.timestamp + 1 hours);
        Attestation memory a = attestation(id, true);
        bytes memory sig = sign(a, ORACLE_KEY, address(intake));
        vm.expectRevert(CabalGate.Expired.selector);
        intake.deliver(gate, id, a, sig);
        vm.prank(BOB);
        vm.expectRevert(CabalGate.NotRequester.selector);
        gate.clearRequest(id);
        vm.prank(ALICE);
        gate.clearRequest(id);
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        assertEq(imd.balanceOf(ALICE), balance - intake.price());
        vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
        intake.deliver(gate, id, a, sig);
        submit(true, 100 ether);
    }

    function test_intakeFailureUnderpaymentDuplicateIdAndReentry() public {
        intake.setFailure(true);
        vm.prank(ALICE);
        vm.expectRevert();
        gate.submitBuyRequest(100 ether, "research");
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        intake.setFailure(false);
        intake.setSkipPayment(true);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.UnsupportedToken.selector);
        gate.submitBuyRequest(100 ether, "research");
        intake.setSkipPayment(false);
        intake.setReenter(true);
        submit(true, 100 ether);
        assertFalse(intake.reentrySucceeded());
        intake.setReuse(true);
        vm.prank(BOB);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.submitBuyRequest(100 ether, "research");
    }

    function test_ownerConfigSnapshotsInvalidatesOldExecutionAndCanClear() public {
        bytes32 id = submit(true, 100 ether);
        approve(id);
        CabalGate.Config memory cfg = gate.configuration();
        cfg.intake = address(new MockIntake());
        cfg.action = bytes32("updated oracle action");
        cfg.signer = vm.addr(ORACLE_KEY + 1);
        cfg.windowHours = 2;
        vm.prank(BOB);
        vm.expectRevert();
        gate.configure(cfg);
        gate.configure(cfg);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.executeBuyRequest(id);
        vm.prank(ALICE);
        gate.clearRequest(id);
        assertEq(gate.configVersion(), 2);
        cfg.imd = address(token);
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
    }

    function test_oldPendingUsesSnapshotIntakeSignerAndDomain() public {
        bytes32 id = submit(true, 100 ether);
        CabalGate.Config memory cfg = gate.configuration();
        cfg.intake = address(new MockIntake());
        cfg.signer = vm.addr(ORACLE_KEY + 1);
        cfg.oracleVerifier = cfg.intake;
        gate.configure(cfg);
        Attestation memory a = attestation(id, true);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(intake)));
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
    }

    function test_wrongChainAndSizeAndConcurrentRequestRejected() public {
        vm.chainId(10);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.WrongChain.selector);
        gate.submitBuyRequest(100 ether, "reason");
        vm.chainId(1);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.LimitExceeded.selector);
        gate.submitBuyRequest(0, "reason");
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.LimitExceeded.selector);
        gate.submitBuyRequest(10001 ether, "reason");
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.LimitExceeded.selector);
        gate.submitSellRequest(100 ether, "reason");
        submit(true, 100 ether);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.ActiveRequest.selector);
        gate.submitBuyRequest(100 ether, "reason");
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool found = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}

contract OracleGasTest is CabalFixture {
    bytes32 private pending;

    function setUp() public override {
        super.setUp();
        pending = submit(true, 100 ether);
    }

    function test_callbackFitsBelow200kColdTransaction() public {
        Attestation memory a = attestation(pending, true);
        uint256 gasUsed = intake.deliverWithGas(gate, pending, a, sign(a, ORACLE_KEY, address(intake)));
        emit log_named_uint("callback gas including external call", gasUsed);
        assertLt(gasUsed, 200000);
    }
}
