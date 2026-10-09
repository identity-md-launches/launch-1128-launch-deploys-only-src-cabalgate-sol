// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CabalGate} from "src/CabalGate.sol";
import {CabalHook} from "src/CabalHook.sol";
import {Attestation} from "src/interfaces/IIntake.sol";
import {OracleSignature} from "src/libraries/OracleSignature.sol";
import {GateLaunchWords, GateLaunchFactory, GateLaunchFixture, MockLaunchHook} from "./GateLaunch.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @notice The gate against the real CabalHook code at the live hook address, in the state launch 953 left it:
///         pool bound to the manifest key, CABAL and IMD inferred from it, gate unset, owned by the hook owner.
///         Nothing is deployed to any chain; the runtime is placed at the address in the test EVM and the one
///         `beforeInitialize` call the PoolManager made at launch is replayed from the PoolManager's address.
///         This pins what the mock in GateLaunch.t.sol only models: the real `setGate` checks and the real ABI
///         encoding of `poolKey()` that the gate compares raw against its constructor-built key.
contract GateLiveHookTest is GateLaunchFixture {
    /// @dev Owner of launch 953's hook, the account that performs the one-time binding after launch.
    address internal constant HOOK_OWNER = 0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774;
    uint256 internal constant LOCAL_SIGNER_KEY = 0x5157;
    CabalHook internal liveHook;

    function setUp() public override {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        launchOwner = makeAddr("launch owner resolves $owner");
        hookOwner = HOOK_OWNER;
        // The constructor validates the permission bits of its own address, so this only succeeds because the
        // live address carries exactly beforeInitialize | beforeSwap | afterSwap.
        deployCodeTo("CabalHook.sol:CabalHook", abi.encode(POOL_MANAGER, HOOK_OWNER, IMD), HOOK);
        liveHook = CabalHook(HOOK);
        vm.prank(POOL_MANAGER);
        liveHook.beforeInitialize(makeAddr("launch 953 factory"), _manifestKey(), uint160(1 << 96));
        deployCodeTo("MockIntake.sol:MockIntake", INTAKE);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Mock IMD", "IMD", uint256(0)), IMD);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Mock CABAL", "CABAL", uint256(0)), CABAL);
        factory = new GateLaunchFactory();
    }

    function _bind(bytes32 salt) internal returns (CabalGate gate) {
        gate = _deploy(salt);
        vm.prank(HOOK_OWNER);
        liveHook.setGate(address(gate));
    }

    function test_liveHookStateReadsExactlyAsTheManifestWordsDescribe() public view {
        assertEq(uint160(HOOK) & Hooks.ALL_HOOK_MASK, uint160(0x20c0), "live address permission bits");
        assertTrue(liveHook.initialized());
        assertEq(address(liveHook.poolManager()), POOL_MANAGER);
        assertEq(liveHook.cabal(), CABAL);
        assertEq(address(liveHook.imd()), IMD);
        assertEq(liveHook.gate(), address(0));
        assertEq(liveHook.owner(), HOOK_OWNER);
        assertEq(keccak256(abi.encode(liveHook.poolKey())), keccak256(abi.encode(_manifestKey())));
        // The raw return data of the real poolKey() is the five-word static encoding the gate hashes.
        (bool ok, bytes memory raw) = HOOK.staticcall(abi.encodeCall(CabalHook.poolKey, ()));
        assertTrue(ok);
        assertEq(raw.length, 5 * 32);
        assertEq(keccak256(raw), keccak256(abi.encode(_manifestKey())));
    }

    function test_realSetGateBindsTheDeployedGateOnceAndRefusesEverythingElse() public {
        CabalGate gate = _deploy(keccak256("live binding"));
        CabalGate second = _deploy(keccak256("second live gate"));
        address builder = address(gate.questionBuilder());
        assertEq(address(gate.hook()), HOOK);
        assertEq(address(gate.cabal()), liveHook.cabal());

        vm.prank(launchOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, launchOwner));
        liveHook.setGate(address(gate));
        vm.startPrank(HOOK_OWNER);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        liveHook.setGate(launchOwner); // no code
        // Code without hook()/cabal() getters: the getter call itself reverts with no data, so the binding fails
        // without reaching InvalidGate; either way nothing is bound.
        vm.expectRevert(bytes(""));
        liveHook.setGate(builder);
        assertEq(liveHook.gate(), address(0));
        vm.expectEmit(HOOK);
        emit CabalHook.GateBound(address(gate));
        liveHook.setGate(address(gate));
        assertEq(liveHook.gate(), address(gate));
        vm.expectRevert(CabalHook.InvalidGate.selector);
        liveHook.setGate(address(second));
        vm.expectRevert(CabalHook.InvalidGate.selector);
        liveHook.setGate(address(gate));
        vm.stopPrank();
        assertEq(liveHook.gate(), address(gate), "binding is permanent");
    }

    /// @dev The sorted key cannot tell CABAL from IMD, so a gate built with the roles swapped deploys; the real
    ///      hook compares cabal() and refuses it, and it can never submit because the hook's cabal() differs.
    function test_realHookRefusesGateBuiltWithSwappedTokenRoles() public {
        bytes memory arguments = _arguments();
        assembly ("memory-safe") {
            mstore(add(arguments, 96), IMD) // cabal
            mstore(add(arguments, 320), CABAL) // imd
        }
        CabalGate swapped = CabalGate(factory.deploy(_creation(arguments), keccak256("swapped on live hook")));
        assertEq(address(swapped.cabal()), IMD);
        vm.prank(HOOK_OWNER);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        liveHook.setGate(address(swapped));
        assertEq(liveHook.gate(), address(0));
    }

    function test_requestsRefusedUntilTheRealHookBindsThenBuySellCallbackAndClearRunOnLiveAddresses() public {
        CabalGate gate = _deploy(keccak256("live request"));
        _preparePool();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _fund(alice, gate);
        _fund(bob, gate);
        _assertRefused(gate, alice, true);
        _assertRefused(gate, bob, false);
        assertEq(MockIntake(INTAKE).nonce(), 0, "a refused request must not reach the intake");

        vm.prank(HOOK_OWNER);
        liveHook.setGate(address(gate));
        // The live signer's key is not available here; the owner's live reconfiguration swaps in a local one
        // and must pass the checks the constructor could not make (intake and IMD have code, IMD is the hook's).
        CabalGate.Config memory cfg = gate.configuration();
        cfg.signer = vm.addr(LOCAL_SIGNER_KEY);
        vm.prank(launchOwner);
        gate.configure(cfg);
        assertEq(gate.configVersion(), 2);

        bytes32 buyId = _assertAccepted(gate, alice, true);
        bytes32 sellId = _assertAccepted(gate, bob, false);
        assertTrue(buyId != sellId);
        (address target, bytes4 selector) = MockIntake(INTAKE).lastCallback();
        assertEq(target, address(gate));
        assertEq(selector, CabalGate.onOracleResult.selector);
        assertEq(MockIntake(INTAKE).lastToken(), IMD);

        // Approval and rejection arrive through the intake under the live 200,000-gas stipend.
        Attestation memory yes = _attestation(gate, buyId, true);
        bytes memory yesSignature = _sign(gate, yes);
        MockIntake(INTAKE).deliver(gate, buyId, yes, yesSignature);
        assertEq(uint8(gate.getRequest(buyId).status), uint8(CabalGate.Status.Approved));
        assertEq(gate.getRequest(buyId).approvedUntil, block.timestamp + gate.APPROVAL_WINDOW());
        assertEq(gate.attestationUsedBy(yes.requestId), buyId);
        Attestation memory no = _attestation(gate, sellId, false);
        bytes memory noSignature = _sign(gate, no);
        MockIntake(INTAKE).deliver(gate, sellId, no, noSignature);
        assertEq(uint8(gate.getRequest(sellId).status), uint8(CabalGate.Status.Rejected));
        assertEq(gate.activeRequest(bob), bytes32(0));
        // A second delivery of the same signed attestation is refused: the request is no longer pending.
        vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
        MockIntake(INTAKE).deliver(gate, buyId, yes, yesSignature);
        // And the consumed oracle id cannot decide another pending request either.
        bytes32 thirdId = _assertAccepted(gate, bob, true);
        Attestation memory replay = _attestation(gate, thirdId, true);
        replay.requestId = yes.requestId;
        bytes memory replaySignature = _sign(gate, replay);
        vm.expectRevert(CabalGate.InvalidAttestation.selector);
        MockIntake(INTAKE).deliver(gate, thirdId, replay, replaySignature);
        assertEq(uint8(gate.getRequest(thirdId).status), uint8(CabalGate.Status.Pending));

        // Alice's approval lapses unexecuted and she clears it; before that the slot is hers alone.
        vm.prank(alice);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.clearRequest(buyId);
        vm.warp(block.timestamp + gate.APPROVAL_WINDOW());
        vm.prank(alice);
        gate.clearRequest(buyId);
        assertEq(uint8(gate.getRequest(buyId).status), uint8(CabalGate.Status.Cleared));
        assertEq(gate.activeRequest(alice), bytes32(0));
        assertEq(IERC20(IMD).balanceOf(address(gate)), 0, "the gate keeps none of the oracle payment");
    }

    /// @dev Between launch and binding, or if the hook ever lost its code, every submission must stop at the
    ///      hook reads without touching the user's tokens; a hook whose poolKey() reverts is treated the same.
    function test_requestRefusedWhenTheHookHasNoCodeOrItsPoolKeyReverts() public {
        CabalGate gate = _bind(keccak256("hook availability"));
        _preparePool();
        address user = makeAddr("availability user");
        _fund(user, gate);
        bytes memory runtime = HOOK.code;

        vm.etch(HOOK, "");
        _assertRefused(gate, user, true);
        _assertRefused(gate, user, false);
        vm.etch(HOOK, runtime);
        assertEq(liveHook.gate(), address(gate), "storage survives the code swap");

        vm.mockCallRevert(HOOK, abi.encodeCall(CabalHook.poolKey, ()), "hook unavailable");
        _assertRefused(gate, user, true);
        vm.clearMockedCalls();
        _preparePool(); // clearMockedCalls also dropped the PoolManager's mocked slot0 and liquidity
        _assertAccepted(gate, user, true);
    }

    /// @dev The gate hashes the raw return data, so a hook that encodes the same key differently (a trailing word,
    ///      a truncated word, a dynamic offset) is not this hook.
    function test_requestRefusedWhenPoolKeyReturnEncodingDiffersEvenWithTheSameFields() public {
        CabalGate gate = _bind(keccak256("encoding"));
        _preparePool();
        address user = makeAddr("encoding user");
        _fund(user, gate);
        bytes memory exact = abi.encode(_manifestKey());
        bytes memory call = abi.encodeCall(CabalHook.poolKey, ());

        vm.mockCall(HOOK, call, bytes.concat(exact, bytes32(0)));
        _assertRefused(gate, user, true);
        bytes memory truncated = new bytes(4 * 32);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = exact[i];
        }
        vm.mockCall(HOOK, call, truncated);
        _assertRefused(gate, user, false);
        vm.mockCall(HOOK, call, bytes.concat(bytes32(uint256(32)), exact));
        _assertRefused(gate, user, true);
        vm.mockCall(HOOK, call, "");
        _assertRefused(gate, user, false);
        vm.mockCall(HOOK, call, exact);
        _assertAccepted(gate, user, true);
    }

    /// @dev Mainnet only: the same Intake and signer exist on Robinhood Chain (4663), where this gate must not
    ///      pay for anything. The chain check runs before the hook reads and before any token interaction.
    function test_requestRefusedOffMainnetBeforeAnyHookReadOrPayment() public {
        CabalGate gate = _bind(keccak256("chain"));
        _preparePool();
        address user = makeAddr("chain user");
        _fund(user, gate);
        uint256 paid = IERC20(IMD).balanceOf(user);
        bytes memory runtime = HOOK.code;
        vm.chainId(4663);
        vm.etch(HOOK, ""); // a hook read here would surface as InvalidConfig, not WrongChain
        vm.startPrank(user);
        vm.expectRevert(CabalGate.WrongChain.selector);
        gate.submitBuyRequest(100 ether, "Pay October hosting");
        vm.expectRevert(CabalGate.WrongChain.selector);
        gate.submitSellRequest(100 ether, "Pay October hosting");
        vm.stopPrank();
        assertEq(IERC20(IMD).balanceOf(user), paid);
        assertEq(MockIntake(INTAKE).nonce(), 0);
        vm.etch(HOOK, runtime);
        vm.chainId(1);
        _assertAccepted(gate, user, true);
    }

    /// @dev The owner's reconfiguration cannot move the gate to an IMD the hook does not pair, to a configuration
    ///      the oracle refuses, or away from the gate's own domain; and only the current owner may do it.
    function test_ownerReconfigurationOnLiveHookKeepsTheBindingChecks() public {
        CabalGate gate = _bind(keccak256("reconfigure"));
        CabalGate.Config memory cfg = gate.configuration();
        vm.prank(HOOK_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, HOOK_OWNER));
        gate.configure(cfg);
        vm.startPrank(launchOwner);
        cfg.imd = CABAL;
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        cfg = gate.configuration();
        cfg.oracleVerifier = address(0);
        gate.configure(cfg);
        assertEq(gate.configuration().oracleVerifier, address(gate), "zero verifier resolves to the gate");
        cfg = gate.configuration();
        cfg.maxDriftBps = cfg.maxImpactBps - 1;
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        vm.stopPrank();
        assertEq(gate.configVersion(), 2);
        assertEq(liveHook.gate(), address(gate));
    }

    function _attestation(CabalGate gate, bytes32 id, bool yes) internal view returns (Attestation memory a) {
        CabalGate.Request memory r = gate.getRequest(id);
        CabalGate.Config memory cfg = gate.configurationAt(r.version);
        a.requestId = keccak256(abi.encode("oracle UUID", id));
        a.chainId = 1;
        a.fromBlock = uint64(block.number - 1);
        a.toBlock = uint64(block.number);
        a.questionHash = gate.questionBuilder().questionHash(gate.questionOf(id), a.fromBlock, a.toBlock);
        a.answerType = 0;
        a.answer = abi.encode(yes);
        a.blockHash = keccak256("observed block");
        a.panelJobId = keccak256(abi.encode("panel UUID", id));
        a.panelSize = cfg.panelSize;
        a.quorum = cfg.quorum;
        a.agreed = cfg.quorum;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 900);
    }

    function digest(Attestation calldata a, address verifier) external pure returns (bytes32) {
        return OracleSignature.digest(a, 1, verifier);
    }

    function _sign(CabalGate gate, Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LOCAL_SIGNER_KEY, this.digest(a, address(gate)));
        return abi.encodePacked(r, s, v);
    }
}

/// @notice Fuzzed deviations on the storage-backed mock: whatever the hook reports, a request goes through only
///         when every read equals what the gate was built from, and the first mismatch costs the user nothing.
contract GateHookReadFuzzTest is GateLaunchFixture {
    CabalGate internal gate;
    address internal user;

    function setUp() public override {
        super.setUp();
        gate = _deploy(keccak256("fuzzed hook reads"));
        _preparePool();
        vm.prank(hookOwner);
        MockLaunchHook(HOOK).setGate(address(gate));
        user = makeAddr("fuzz user");
        _fund(user, gate);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_onlyTheExactPoolKeyIsAccepted(uint8 fieldSeed, uint256 valueSeed, bool buy) public {
        PoolKey memory key = _manifestKey();
        uint256 field = bound(fieldSeed, 0, 4);
        if (field == 0) key.currency0 = Currency.wrap(address(uint160(valueSeed)));
        else if (field == 1) key.currency1 = Currency.wrap(address(uint160(valueSeed)));
        else if (field == 2) key.fee = uint24(valueSeed);
        else if (field == 3) key.tickSpacing = int24(uint24(valueSeed));
        else key.hooks = IHooks(address(uint160(valueSeed)));
        MockLaunchHook(HOOK).reportKey(key);
        bool same = keccak256(abi.encode(key)) == keccak256(abi.encode(_manifestKey()));
        if (same) {
            _assertAccepted(gate, user, buy);
        } else {
            _assertRefused(gate, user, buy);
            MockLaunchHook(HOOK).reportKey(_manifestKey());
            _assertAccepted(gate, user, buy);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_onlyTheExactCabalImdAndGateAreAccepted(address cabal, address imd, address reported, bool buy)
        public
    {
        MockLaunchHook(HOOK).reportTokens(cabal, imd);
        MockLaunchHook(HOOK).reportGate(reported);
        if (cabal == CABAL && imd == IMD && reported == address(gate)) {
            _assertAccepted(gate, user, buy);
        } else {
            _assertRefused(gate, user, buy);
            MockLaunchHook(HOOK).reportTokens(CABAL, IMD);
            MockLaunchHook(HOOK).reportGate(address(gate));
            _assertAccepted(gate, user, buy);
        }
    }

    function test_pinnedNearMisses() public {
        // One bit off in each address-valued read, the dynamic-fee flag, and the hook's own address as gate.
        MockLaunchHook(HOOK).reportTokens(address(uint160(CABAL) ^ 1), IMD);
        _assertRefused(gate, user, true);
        MockLaunchHook(HOOK).reportTokens(CABAL, address(uint160(IMD) ^ 1));
        _assertRefused(gate, user, false);
        MockLaunchHook(HOOK).reportTokens(CABAL, IMD);
        MockLaunchHook(HOOK).reportGate(HOOK);
        _assertRefused(gate, user, true);
        MockLaunchHook(HOOK).reportGate(address(uint160(address(gate)) ^ 1));
        _assertRefused(gate, user, false);
        MockLaunchHook(HOOK).reportGate(address(gate));
        PoolKey memory key = _manifestKey();
        key.fee = 0x800000;
        MockLaunchHook(HOOK).reportKey(key);
        _assertRefused(gate, user, true);
        key = _manifestKey();
        key.hooks = IHooks(address(uint160(HOOK) ^ (1 << 20)));
        MockLaunchHook(HOOK).reportKey(key);
        _assertRefused(gate, user, false);
        MockLaunchHook(HOOK).reportKey(_manifestKey());
        _assertAccepted(gate, user, true);
    }
}

/// @notice In the launch rehearsal's empty EVM the gate deploys, and then nothing can move through it until the
///         chain it was built for is really there: every submission stops at the hook reads and the owner cannot
///         reconfigure it onto an Intake or IMD that has no code.
contract GateEmptyEvmUsageTest is GateLaunchWords {
    function test_gateIsInertButIntactUntilItsDependenciesHaveCode() public {
        vm.chainId(1);
        address owner = makeAddr("launch owner resolves $owner");
        GateLaunchFactory factory = new GateLaunchFactory();
        CabalGate gate = CabalGate(factory.deploy(_creation(_words(owner)), keccak256("inert")));
        assertEq(HOOK.code.length, 0);
        assertEq(IMD.code.length, 0);
        vm.startPrank(owner);
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.submitBuyRequest(1 ether, "Pay October hosting");
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.submitSellRequest(1 ether, "Pay October hosting");
        CabalGate.Config memory cfg = gate.configuration();
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        vm.stopPrank();
        assertEq(gate.configVersion(), 1);
        assertEq(gate.activeRequest(owner), bytes32(0));
        // Ownership, the only privilege the gate has, is live and two-step even here.
        address next = makeAddr("next owner");
        vm.prank(owner);
        gate.transferOwnership(next);
        vm.prank(next);
        gate.acceptOwnership();
        assertEq(gate.owner(), next);
    }
}
