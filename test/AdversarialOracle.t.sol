// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CabalFixture} from "./CabalFixture.sol";
import {CabalGate} from "src/CabalGate.sol";
import {IIntake, Attestation} from "src/interfaces/IIntake.sol";
import {MainnetDefaults} from "src/libraries/MainnetDefaults.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AdversarialOracleTest is CabalFixture {
    function test_everySignedFieldRejectsPostSignatureMutation() public {
        bytes32 id = submit(true, 100 ether);
        for (uint256 field; field < 16; ++field) {
            Attestation memory a = attestation(id, true);
            // Keep the original issue time and validity away from boundaries so mutations to
            // otherwise valid fields test signature binding, not merely input validation.
            vm.warp(block.timestamp + 2);
            bytes memory signature = sign(a, ORACLE_KEY, address(gate));
            if (field == 0) a.requestId = bytes32(uint256(id) + 1);
            if (field == 1) a.chainId = 2;
            if (field == 2) a.questionHash = keccak256("changed question");
            if (field == 3) a.answerType = 1;
            if (field == 4) a.answer = abi.encode(false);
            if (field == 5) a.fromBlock -= 1;
            if (field == 6) a.toBlock -= 1;
            if (field == 7) a.blockHash = keccak256("different nonzero block");
            if (field == 8) a.panelJobId = keccak256("different panel job");
            if (field == 9) a.panelSize = 31;
            if (field == 10) a.quorum = 21;
            if (field == 11) a.agreed += 1;
            if (field == 12) a.issuedAt += 1;
            if (field == 13) a.expiresAt -= 1;
            if (field == 14) a.answer = abi.encode(uint256(2));
            if (field == 15) a.figure = 1;
            vm.expectRevert(CabalGate.InvalidAttestation.selector);
            intake.deliver(gate, id, a, signature);
            assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
            assertEq(gate.activeRequest(ALICE), id);
        }
    }

    function test_signatureRejectsWrongNameVersionAndDomainChain() public {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
        for (uint256 i; i < 4; ++i) {
            bytes32 domain = keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(i == 0 ? "IdentityMD oracle" : "IdentityMD Oracle")),
                    keccak256(bytes(i == 1 ? "1" : "2")),
                    i == 2 ? uint256(2) : uint256(1),
                    i == 3 ? address(intake) : address(gate)
                )
            );
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(ORACLE_KEY, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
            vm.expectRevert(CabalGate.InvalidAttestation.selector);
            intake.deliver(gate, id, a, abi.encodePacked(r, s, v));
        }
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(gate)));
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
    }

    function test_signatureRejectsHighSAndInvalidV() public {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        bytes memory signature = sign(a, ORACLE_KEY, address(gate));
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        bytes32 highS = bytes32(0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141 - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        intake.deliver(gate, id, a, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        intake.deliver(gate, id, a, abi.encodePacked(r, s, uint8(0)));
        intake.deliver(gate, id, a, signature);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_malformedSignatureLengthCannotConsumeRequest(uint8 length) public {
        uint256 n = bound(length, 0, 128);
        if (n == 65) n = 66;
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, n));
        intake.deliver(gate, id, a, new bytes(n));
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
        assertEq(gate.activeRequest(ALICE), id);
    }

    function test_callbackHasNoDependencyOnTokenNftIntakeOrPoolReads() public {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        bytes memory signature = sign(a, ORACLE_KEY, address(gate));
        vm.mockCallRevert(address(imd), abi.encodeWithSignature("balanceOf(address)"), "token unavailable");
        vm.mockCallRevert(address(token), abi.encodeWithSignature("balanceOf(address)"), "token unavailable");
        vm.mockCallRevert(gate.IDENTITY_NFT(), abi.encodeWithSignature("balanceOf(address)"), "NFT unavailable");
        vm.mockCallRevert(address(manager), abi.encodeWithSignature("extsload(bytes32)"), "pool unavailable");
        vm.mockCallRevert(address(intake), abi.encodeWithSelector(IIntake.priceOf.selector), "quote unavailable");
        uint256 used = intake.deliverWithGas(gate, id, a, signature);
        assertLt(used, 200000);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
        vm.clearMockedCalls();
        assertSettled();
    }

    function test_zeroOraclePriceAndZeroReturnedIdAreHandledAtomically() public {
        intake.setPrice(0);
        uint256 beforeBalance = imd.balanceOf(ALICE);
        vm.mockCall(address(intake), abi.encodeWithSelector(IIntake.request.selector), abi.encode(bytes32(0)));
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.submitBuyRequest(100 ether, "Pay October server hosting");
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        assertEq(imd.balanceOf(ALICE), beforeBalance);
        vm.clearMockedCalls();
        bytes32 id = submit(true, 100 ether);
        assertEq(imd.balanceOf(ALICE), beforeBalance);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
        assertSettled();
    }

    function test_failedOraclePaymentLeavesNoRequestAndCanRetry() public {
        vm.prank(ALICE);
        imd.approve(address(gate), 0);
        uint256 price = intake.price();
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gate), 0, price)
        );
        gate.submitBuyRequest(100 ether, "Pay October server hosting");
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        assertEq(imd.balanceOf(address(intake)), 0);
        vm.prank(ALICE);
        imd.approve(address(gate), price);
        bytes32 id = submit(true, 100 ether);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
        assertEq(imd.allowance(ALICE, address(gate)), 0);
        assertSettled();
    }

    function test_rejectedAndClearedIdsCannotReplayOrAlterNewActiveRequest() public {
        bytes32 rejected = submit(true, 100 ether);
        Attestation memory a = attestation(rejected, false);
        intake.deliver(gate, rejected, a, sign(a, ORACLE_KEY, address(gate)));
        bytes32 cleared = submit(true, 100 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(ALICE);
        gate.clearRequest(cleared);
        bytes32 pending = submit(true, 100 ether);
        bytes32[2] memory terminal = [rejected, cleared];
        for (uint256 i; i < terminal.length; ++i) {
            a = attestation(terminal[i], true);
            bytes memory signature = sign(a, ORACLE_KEY, address(gate));
            vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
            intake.deliver(gate, terminal[i], a, signature);
            vm.startPrank(ALICE);
            vm.expectRevert(CabalGate.InvalidRequest.selector);
            gate.executeBuyRequest(terminal[i]);
            vm.expectRevert(CabalGate.InvalidRequest.selector);
            gate.clearRequest(terminal[i]);
            vm.expectRevert(CabalGate.InvalidRequest.selector);
            gate.setSlippageLimit(terminal[i], 1);
            vm.stopPrank();
            assertEq(gate.activeRequest(ALICE), pending);
        }
    }

    function test_timeoutAndApprovalBoundaryAtLastPermittedSecond() public {
        bytes32 id = submit(true, 100 ether);
        vm.warp(block.timestamp + 3599);
        approve(id);
        uint256 deadline = gate.getRequest(id).approvedUntil;
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.clearRequest(id);
        vm.warp(deadline - 1);
        vm.prank(ALICE);
        assertGt(gate.executeBuyRequest(id), 0);
        assertSettled();
    }

    function test_configurationRejectsEveryInvalidBoundaryWithoutAdvancingVersion() public {
        for (uint256 field; field < 22; ++field) {
            CabalGate.Config memory cfg = gate.configuration();
            if (field == 0) cfg.intake = address(0);
            if (field == 1) cfg.intake = ALICE;
            if (field == 2) cfg.imd = address(token);
            if (field == 3) cfg.signer = address(0);
            if (field == 4) cfg.maxDriftBps = cfg.maxImpactBps - 1;
            if (field == 5) cfg.action = bytes32(0);
            if (field == 6) cfg.maxBuyAmount = 0;
            if (field == 7) cfg.maxSellAmount = 0;
            if (field == 8) cfg.maxBuyAmount = uint128(type(int128).max) + 1;
            if (field == 9) cfg.maxSellAmount = uint128(type(int128).max) + 1;
            if (field == 10) cfg.maxImpactBps = 0;
            if (field == 11) (cfg.maxImpactBps, cfg.maxDriftBps) = (5001, 5001);
            if (field == 12) cfg.windowHours = 0;
            if (field == 13) cfg.windowHours = 25;
            if (field == 14) cfg.maxDriftBps = 5001;
            if (field == 15) cfg.quorum = 0;
            if (field == 16) cfg.quorum = cfg.panelSize + 1;
            if (field == 17) (cfg.panelSize, cfg.quorum) = (1001, 1);
            if (field == 18) cfg.imd = address(0);
            // The oracle refuses panelSize or quorum outside 2..300: such a request is paid and never answered.
            if (field == 19) cfg.quorum = 1;
            if (field == 20) (cfg.panelSize, cfg.quorum) = (301, 300);
            if (field == 21) (cfg.panelSize, cfg.quorum) = (1, 1);
            vm.expectRevert(CabalGate.InvalidConfig.selector);
            gate.configure(cfg);
            assertEq(gate.configVersion(), 1);
        }
        // The largest values the gate accepts are valid, and every accepted update is a new version.
        CabalGate.Config memory edge = gate.configuration();
        (edge.maxImpactBps, edge.maxDriftBps, edge.panelSize, edge.quorum, edge.windowHours) =
        (5000, 5000, 300, 300, 24);
        gate.configure(edge);
        assertEq(gate.configVersion(), 2);
        (edge.panelSize, edge.quorum) = (2, 2);
        gate.configure(edge);
        assertEq(gate.configVersion(), 3);
    }

    /// @dev A zero verifier is not a misconfiguration: the gate substitutes itself and declares that in the body.
    function test_zeroVerifierMeansThisGateAndIsStoredResolved() public {
        CabalGate.Config memory cfg = gate.configuration();
        cfg.oracleVerifier = address(0);
        gate.configure(cfg);
        assertEq(gate.configuration().oracleVerifier, address(gate));
        bytes32 id = submit(true, 100 ether);
        assertEq(vm.parseJsonAddress(string(intake.bodyOf(id)), ".consumer.verifyingContract"), address(gate));
    }

    /// @dev An explicit verifier is the domain the oracle signs for: a signature under the gate's own domain is
    ///      then a forgery, and the body tells the oracle which consumer to sign for.
    function test_explicitVerifierReplacesGateInDomainAndBody() public {
        CabalGate.Config memory cfg = gate.configuration();
        cfg.oracleVerifier = BOB;
        gate.configure(cfg);
        bytes32 id = submit(true, 100 ether);
        assertEq(vm.parseJsonAddress(string(intake.bodyOf(id)), ".consumer.verifyingContract"), BOB);
        Attestation memory a = attestation(id, true);
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(gate)));
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, BOB));
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
    }

    /// @dev An attestation issued before the request existed cannot be a decision about it, however well signed:
    ///      a pre-signed approval harvested from an earlier question with the same text is refused.
    function test_attestationIssuedBeforeSubmissionIsRefused() public {
        vm.warp(block.timestamp + 1 days);
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        a.issuedAt = uint64(block.timestamp - 1);
        a.expiresAt = a.issuedAt + 900;
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(gate)));
        a.issuedAt = uint64(block.timestamp);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(gate)));
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
    }

    /// @dev The oracle's answer is bound to this request's stored question: the same signer approving the same
    ///      text for a different window, or a different requester's identical reason, does not transfer.
    function test_identicalReasonFromAnotherUserDoesNotShareAttestation() public {
        bytes32 idA = submit(true, 100 ether);
        bytes32 idB = submitAs(BOB, true, 100 ether);
        assertTrue(keccak256(gate.questionOf(idA)) != keccak256(gate.questionOf(idB)), "questions must name the user");
        Attestation memory forB = attestation(idB, true);
        forB.requestId = oracleIdOf(idA);
        bytes memory signature = sign(forB, ORACLE_KEY, address(gate));
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, idA, forB, signature);
        intake.deliver(gate, idB, forB, signature);
        assertEq(uint8(gate.getRequest(idB).status), uint8(CabalGate.Status.Approved));
        assertEq(uint8(gate.getRequest(idA).status), uint8(CabalGate.Status.Pending));
    }

    /// @dev A rejected answer frees the slot but the stored question blob and attestation id stay consumed:
    ///      resubmitting the same text produces a fresh question and a decision for it cannot be forged from the old one.
    function test_rejectionReleasesSlotAndResubmissionNeedsFreshDecision() public {
        bytes32 first = submit(true, 100 ether);
        Attestation memory no = attestation(first, false);
        intake.deliver(gate, first, no, sign(no, ORACLE_KEY, address(gate)));
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        assertEq(gate.attestationUsedBy(no.requestId), first);
        bytes32 second = submit(true, 100 ether);
        assertTrue(second != first);
        assertEq(keccak256(gate.questionOf(second)), keccak256(gate.questionOf(first)), "same text, same question");
        Attestation memory yes = attestation(second, true);
        yes.requestId = no.requestId;
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        intake.deliver(gate, second, yes, sign(yes, ORACLE_KEY, address(gate)));
        assertEq(uint8(gate.getRequest(second).status), uint8(CabalGate.Status.Pending));
    }

    /// @dev The unused `mainnetConfig` view was removed to keep the gate under EIP-170; the defaults it echoed
    ///      live in MainnetDefaults and the launch words (test/GateLaunch.t.sol), checked here against the brief.
    function test_mainnetDefaultsMatchAssignment() public view {
        assertEq(MainnetDefaults.INTAKE, 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56);
        assertEq(MainnetDefaults.IMD, 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(MainnetDefaults.SIGNER, 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertEq(MainnetDefaults.ACTION, bytes32("oracle.request@oracle-1"));
        assertEq(MainnetDefaults.ACTION, 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000);
        assertEq(gate.IDENTITY_NFT(), address(bytes20(hex"0000ec93127baa929e58e97dd0095a2bfb38ec1d")));
        assertEq(gate.configuration().oracleVerifier, address(gate));
        assertEq(gate.configuration().boolAnswerType, 0);
    }
}
