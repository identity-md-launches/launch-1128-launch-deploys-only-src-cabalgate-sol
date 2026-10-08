// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GateLaunchFixture, MockLaunchHook} from "./GateLaunch.t.sol";
import {CabalGate} from "src/CabalGate.sol";
import {CabalHook} from "src/CabalHook.sol";
import {Attestation} from "src/interfaces/IIntake.sol";
import {OracleSignature} from "src/libraries/OracleSignature.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract GateFactoryEdgesTest is GateLaunchFixture {
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_flatWordsPreserveValidConfiguration(
        uint128 buy,
        uint128 sell,
        uint16 impact,
        uint16 drift,
        uint16 panel,
        uint16 quorum,
        uint8 hours_
    ) public {
        buy = uint128(bound(buy, 1, uint128(type(int128).max)));
        sell = uint128(bound(sell, 1, uint128(type(int128).max)));
        impact = uint16(bound(impact, 1, 5000));
        drift = uint16(bound(drift, impact, 5000));
        panel = uint16(bound(panel, 2, 300));
        quorum = uint16(bound(quorum, 2, panel));
        hours_ = uint8(bound(hours_, 1, 24));
        bytes memory args =
            abi.encode(HOOK, launchOwner, INTAKE, IMD, SIGNER, ACTION, buy, sell, impact, drift, panel, quorum, hours_);
        CabalGate gate = CabalGate(factory.deploy(_creation(args), keccak256(args)));
        CabalGate.Config memory expected = CabalGate.Config(
            INTAKE, IMD, SIGNER, address(gate), ACTION, buy, sell, impact, drift, panel, quorum, hours_, 0
        );
        assertEq(abi.encode(gate.configuration()), abi.encode(expected));
        assertEq(gate.owner(), launchOwner);
        assertEq(gate.configVersion(), 1);
    }

    function test_pinnedValidNumericEdges() public {
        _checkEdges(1, 1, 1, 1, 2, 2, 1);
        _checkEdges(uint128(type(int128).max), uint128(type(int128).max), 5000, 5000, 300, 300, 24);
    }

    function _checkEdges(
        uint128 buy,
        uint128 sell,
        uint16 impact,
        uint16 drift,
        uint16 panel,
        uint16 quorum,
        uint8 hours_
    ) private {
        bytes memory args = abi.encode(
            HOOK, launchOwner, INTAKE, IMD, SIGNER, ACTION, buy, sell, impact, drift, panel, quorum, hours_
        );
        CabalGate gate = CabalGate(factory.deploy(_creation(args), keccak256(args)));
        CabalGate.Config memory expected = CabalGate.Config(
            INTAKE, IMD, SIGNER, address(gate), ACTION, buy, sell, impact, drift, panel, quorum, hours_, 0
        );
        assertEq(abi.encode(gate.configuration()), abi.encode(expected));
    }

    function test_constructorRejectsDirtyHighBitsInEveryNarrowWord() public {
        // A static-word factory must not silently truncate an address or an integer.
        for (uint256 index; index < 13; ++index) {
            if (index == 5) continue; // bytes32 action uses all 256 bits.
            uint256 width = index < 5 ? 160 : index < 8 ? 128 : index < 12 ? 16 : 8;
            bytes memory args = _arguments();
            assembly ("memory-safe") {
                let word := add(add(args, 32), mul(index, 32))
                mstore(word, or(mload(word), shl(width, 1)))
            }
            bytes memory creation = _creation(args);
            vm.expectRevert("application constructor failed");
            factory.deploy(creation, bytes32(index));
        }
    }

    function test_constructorRejectsTruncatedStaticArguments() public {
        for (uint256 words; words < 13; ++words) {
            bytes memory args = _arguments();
            assembly ("memory-safe") { mstore(args, mul(words, 32)) }
            bytes memory creation = _creation(args);
            vm.expectRevert("application constructor failed");
            factory.deploy(creation, bytes32(words));
        }
    }

    function test_helpersAreCreatedByEachGateAndExistingDependenciesStayIntact() public {
        bytes32 hookCode = HOOK.codehash;
        bytes32 imdCode = IMD.codehash;
        address existingCabal = MockLaunchHook(HOOK).cabal();
        bytes32 cabalCode = existingCabal.codehash;
        uint64 hookNonce = vm.getNonce(HOOK);
        CabalGate first = _deploy(keccak256("isolated first"));
        CabalGate second = _deploy(keccak256("isolated second"));
        assertEq(address(first.questionBuilder()), vm.computeCreateAddress(address(first), 1));
        assertEq(address(first.estimator()), vm.computeCreateAddress(address(first), 2));
        assertEq(address(second.questionBuilder()), vm.computeCreateAddress(address(second), 1));
        assertEq(address(second.estimator()), vm.computeCreateAddress(address(second), 2));
        assertEq(vm.getNonce(address(first)), 3, "gate constructor created unexpected contracts");
        assertEq(vm.getNonce(address(second)), 3);
        assertNotEq(address(first.questionBuilder()), address(second.questionBuilder()));
        assertNotEq(address(first.estimator()), address(second.estimator()));
        assertEq(first.configuration().oracleVerifier, address(first));
        assertEq(second.configuration().oracleVerifier, address(second));
        assertEq(HOOK.codehash, hookCode);
        assertEq(IMD.codehash, imdCode);
        assertEq(existingCabal.codehash, cabalCode);
        assertEq(vm.getNonce(HOOK), hookNonce);
        assertEq(MockLaunchHook(HOOK).gate(), address(0));
    }

    function test_hookRejectsMissingCodeWrongHookWrongCabalAndDuplicateBinding() public {
        CabalGate gate = _deploy(keccak256("binding edges"));
        vm.startPrank(hookOwner);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        MockLaunchHook(HOOK).setGate(launchOwner);

        vm.mockCall(address(gate), abi.encodeWithSelector(gate.hook.selector), abi.encode(address(this)));
        vm.expectRevert(CabalHook.InvalidGate.selector);
        MockLaunchHook(HOOK).setGate(address(gate));
        vm.clearMockedCalls();

        vm.mockCall(address(gate), abi.encodeWithSelector(gate.cabal.selector), abi.encode(IMD));
        vm.expectRevert(CabalHook.InvalidGate.selector);
        MockLaunchHook(HOOK).setGate(address(gate));
        vm.clearMockedCalls();
        assertEq(MockLaunchHook(HOOK).gate(), address(0));

        MockLaunchHook(HOOK).setGate(address(gate));
        vm.expectRevert(CabalHook.InvalidGate.selector);
        MockLaunchHook(HOOK).setGate(address(gate));
        vm.stopPrank();
        assertEq(MockLaunchHook(HOOK).gate(), address(gate));
    }

    function test_factoryOwnerHandoverRequiresAcceptanceAndPreservesBinding() public {
        CabalGate gate = _deploy(keccak256("handover"));
        vm.prank(hookOwner);
        MockLaunchHook(HOOK).setGate(address(gate));
        address nextOwner = makeAddr("new gate owner");
        CabalGate.Config memory cfg = gate.configuration();
        cfg.windowHours = 2;
        vm.prank(launchOwner);
        gate.transferOwnership(nextOwner);
        assertEq(gate.owner(), launchOwner);
        assertEq(gate.pendingOwner(), nextOwner);
        vm.prank(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nextOwner));
        gate.configure(cfg);
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        gate.acceptOwnership();
        vm.prank(nextOwner);
        gate.acceptOwnership();
        vm.prank(launchOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, launchOwner));
        gate.configure(cfg);
        vm.prank(nextOwner);
        gate.configure(cfg);
        assertEq(gate.owner(), nextOwner);
        assertEq(gate.pendingOwner(), address(0));
        assertEq(gate.configuration().windowHours, 2);
        assertEq(gate.configurationAt(1).windowHours, 1);
        assertEq(MockLaunchHook(HOOK).gate(), address(gate));
        assertEq(address(gate.hook()), HOOK);
        assertEq(address(gate.cabal()), MockLaunchHook(HOOK).cabal());
    }

    // Unmodified constants from the supplied oracle-consumer/REFERENCE.md conformance vector.
    // The gate is mainnet/bool-only, so the generic array/Sepolia vector tests its production digest library.
    function test_protocolVectorPinsAllFifteenFieldsTypeStringAndDomain() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        Attestation memory a = Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
        bytes32 digest = this.protocolDigest(a);
        assertEq(digest, 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c);
        bytes memory signature =
            hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
        assertEq(ECDSA.recover(digest, signature), 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        assertEq(
            CabalGate.onOracleResult.selector,
            bytes4(
                keccak256(
                    "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                )
            )
        );
    }

    function protocolDigest(Attestation calldata a) external pure returns (bytes32) {
        return OracleSignature.digest(a, 11155111, 0x0000000000000000000000000000000000002748);
    }
}
