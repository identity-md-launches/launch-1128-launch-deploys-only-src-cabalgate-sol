// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {CabalHook} from "../src/CabalHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Models the live hook as the gate reads it: initialized, poolKey, poolManager, imd, cabal and gate, plus the
///      owner-only, one-time binding. Storage-backed so a test can make it report another pool, CABAL, IMD or gate
///      than the one the gate was built for; the live hook has no such setters.
contract MockLaunchHook {
    address public immutable owner;
    IPoolManager public constant poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    bool public initialized = true;
    address public cabal;
    IERC20 public imd;
    address public gate;
    PoolKey private _key;

    constructor(address owner_, address cabal_, address imd_) {
        owner = owner_;
        cabal = cabal_;
        imd = IERC20(imd_);
        (address c0, address c1) = cabal_ < imd_ ? (cabal_, imd_) : (imd_, cabal_);
        _key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(this)));
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    /// @dev Same checks as the live CabalHook.setGate: hook() and cabal() only, never the key.
    function setGate(address candidate) external {
        if (msg.sender != owner) revert Ownable.OwnableUnauthorizedAccount(msg.sender);
        if (
            !initialized || gate != address(0) || candidate.code.length == 0
                || address(CabalGate(candidate).hook()) != address(this)
                || address(CabalGate(candidate).cabal()) != cabal
        ) revert CabalHook.InvalidGate();
        gate = candidate;
    }

    function reportKey(PoolKey memory key) external {
        _key = key;
    }

    function reportTokens(address cabal_, address imd_) external {
        cabal = cabal_;
        imd = IERC20(imd_);
    }

    function reportGate(address gate_) external {
        gate = gate_;
    }
}

/// @dev Uses the protected floor's CREATE2 and size checks, with no initialization calls.
contract GateLaunchFactory {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        require(code.length > 0 && code.length <= 49_152, "invalid init code");
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "application constructor failed");
    }
}

/// @dev The manifest's fifteen constructor words for the live hook of launch 953, as read on 2026-10-08. The pool
///      fee and tick spacing are constants of the gate, and the currencies are CABAL and IMD sorted by address.
abstract contract GateLaunchWords is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant HOOK = 0xf41B6Ff942a082C0d320a0C151310ac2A922a0c0;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant CABAL = 0x450e5910DEcEe15c3AC056E3ed66Cb5ea3Dd33BE;
    address internal constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 internal constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    /// @dev The live pool's fee and tick spacing, which CabalHook.beforeInitialize accepts and nothing else.
    uint24 internal constant FEE = 12500;
    int24 internal constant TICK_SPACING = 60;

    /// @dev Order: hook, poolManager, cabal, initialOwner, intake, imd, signer, action, maxBuyAmount, maxSellAmount,
    ///      maxImpactBps, maxDriftBps, panelSize, quorum, windowHours.
    function _words(address owner) internal pure returns (bytes memory) {
        return abi.encode(
            HOOK,
            POOL_MANAGER,
            CABAL,
            owner,
            INTAKE,
            IMD,
            SIGNER,
            ACTION,
            uint128(1000000000000000000000000),
            uint128(10000000000000000000000000),
            uint16(300),
            uint16(500),
            uint16(30),
            uint16(20),
            uint8(1)
        );
    }

    /// @dev The key the constructor derives from the words: CABAL sorts below IMD, so it is currency0.
    function _manifestKey() internal pure returns (PoolKey memory) {
        return _sortedKey(CABAL, IMD, HOOK);
    }

    function _sortedKey(address cabal, address imd, address hook) internal pure returns (PoolKey memory) {
        (address c0, address c1) = cabal < imd ? (cabal, imd) : (imd, cabal);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, TICK_SPACING, IHooks(hook));
    }

    function _creation(bytes memory arguments) internal view returns (bytes memory) {
        return bytes.concat(vm.getCode("CabalGate.sol:CabalGate"), arguments);
    }

    function _expectedConfig(address gate) internal pure returns (CabalGate.Config memory) {
        return CabalGate.Config(INTAKE, IMD, SIGNER, gate, ACTION, 1e24, 1e25, 300, 500, 30, 20, 1, 0);
    }

    function _assertRuntime(address application) internal view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }
}

/// @notice What the launch checks do: deploy the gate by CREATE2 in an EVM where nothing it names has code. Launch
///         990 parked here because the constructor read the hook and required code at the Intake and IMD.
contract GateEmptyEvmLaunchTest is GateLaunchWords {
    function test_gateDeploysInAnEmptyEvmWithTheManifestWords() public {
        vm.chainId(1);
        address owner = makeAddr("launch owner resolves $owner");
        assertEq(HOOK.code.length, 0, "hook must have no code in this rehearsal");
        assertEq(POOL_MANAGER.code.length, 0, "pool manager must have no code in this rehearsal");
        assertEq(INTAKE.code.length, 0, "intake must have no code in this rehearsal");
        assertEq(IMD.code.length, 0, "imd must have no code in this rehearsal");
        assertEq(CABAL.code.length, 0, "cabal must have no code in this rehearsal");

        bytes memory arguments = _words(owner);
        assertEq(arguments.length, 15 * 32, "the manifest allows at most sixteen words");
        bytes memory creation = _creation(arguments);
        assertLe(creation.length, 49_152, "init code exceeds the factory bound");
        GateLaunchFactory factory = new GateLaunchFactory();
        bytes32 salt = keccak256("launch 990 retry");
        address predicted = vm.computeCreate2Address(salt, keccak256(creation), address(factory));
        CabalGate gate = CabalGate(factory.deploy(creation, salt));
        assertEq(address(gate), predicted);

        _assertRuntime(address(gate));
        _assertRuntime(address(gate.questionBuilder()));
        _assertRuntime(address(gate.estimator()));
        assertEq(address(gate.hook()), HOOK, "hook() getter must return the supplied hook");
        assertEq(address(gate.cabal()), CABAL, "cabal() getter must return the supplied CABAL");
        assertEq(address(gate.poolManager()), POOL_MANAGER);
        assertEq(gate.POOL_FEE(), FEE, "pool fee is a constant of the gate");
        assertEq(gate.POOL_TICK_SPACING(), TICK_SPACING, "tick spacing is a constant of the gate");
        assertEq(address(gate.estimator().poolManager()), POOL_MANAGER);
        assertEq(gate.owner(), owner);
        assertNotEq(gate.owner(), address(factory));
        assertEq(gate.configVersion(), 1);
        assertEq(abi.encode(gate.configuration()), abi.encode(_expectedConfig(address(gate))));
        // Still nothing at the dependency addresses: the constructor created only its two helpers.
        assertEq(HOOK.code.length, 0);
        assertEq(POOL_MANAGER.code.length, 0);
        assertEq(INTAKE.code.length, 0);
        assertEq(IMD.code.length, 0);
        assertEq(vm.getNonce(address(gate)), 3);
    }
}

/// @dev The live addresses carry mocks of what the gate reads there after launch; the gate itself is deployed from
///      the same fifteen words as above.
abstract contract GateLaunchFixture is GateLaunchWords {
    address internal launchOwner;
    address internal hookOwner;
    GateLaunchFactory internal factory;

    function setUp() public virtual {
        vm.chainId(1);
        launchOwner = makeAddr("launch owner resolves $owner");
        hookOwner = makeAddr("existing hook owner");
        deployCodeTo("GateLaunch.t.sol:MockLaunchHook", abi.encode(hookOwner, CABAL, IMD), HOOK);
        deployCodeTo("MockIntake.sol:MockIntake", INTAKE);
        vm.etch(IMD, address(new MockERC20("Mock IMD", "IMD", 0)).code);
        factory = new GateLaunchFactory();
    }

    function _arguments() internal view returns (bytes memory) {
        return _words(launchOwner);
    }

    function _deploy(bytes32 salt) internal returns (CabalGate) {
        return CabalGate(factory.deploy(_creation(_arguments()), salt));
    }

    /// @dev Enough pool state for a submission: a CABAL token, slot0 at price 1 and active liquidity for exactly
    ///      the manifest key, served by the PoolManager address the gate was built with.
    function _preparePool() internal {
        vm.etch(CABAL, IMD.code);
        _preparePoolFor(_manifestKey());
    }

    function _preparePoolFor(PoolKey memory key) internal {
        bytes32 stateSlot = keccak256(abi.encode(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(bytes32(uint256(1 << 96)))
        );
        vm.mockCall(
            POOL_MANAGER,
            abi.encodeWithSignature("extsload(bytes32)", bytes32(uint256(stateSlot) + 3)),
            abi.encode(bytes32(uint256(10_000_000 ether)))
        );
    }

    function _fund(address user, CabalGate gate) internal {
        _fund(user, gate, CABAL);
    }

    function _fund(address user, CabalGate gate, address cabal) internal {
        MockERC20(IMD).mint(user, 1000 ether);
        MockERC20(cabal).mint(user, 1000 ether);
        vm.startPrank(user);
        IERC20(IMD).approve(address(gate), type(uint256).max);
        IERC20(cabal).approve(address(gate), type(uint256).max);
        vm.stopPrank();
    }

    function _assertRefused(CabalGate gate, address user, bool buy) internal {
        uint256 paid = IERC20(IMD).balanceOf(user);
        vm.prank(user);
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        if (buy) gate.submitBuyRequest(100 ether, "Pay October hosting");
        else gate.submitSellRequest(100 ether, "Pay October hosting");
        assertEq(IERC20(IMD).balanceOf(user), paid, "a refused request must not pay the oracle");
        assertEq(gate.activeRequest(user), bytes32(0));
    }

    function _assertAccepted(CabalGate gate, address user, bool buy) internal returns (bytes32 id) {
        uint256 price = MockIntake(INTAKE).price();
        uint256 paid = IERC20(IMD).balanceOf(user);
        uint256 collected = IERC20(IMD).balanceOf(INTAKE);
        vm.prank(user);
        id = buy
            ? gate.submitBuyRequest(100 ether, "Pay October hosting")
            : gate.submitSellRequest(100 ether, "Pay October hosting");
        assertTrue(id != bytes32(0));
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
        assertEq(gate.getRequest(id).requester, user);
        assertEq(gate.activeRequest(user), id);
        assertEq(IERC20(IMD).balanceOf(user), paid - price);
        assertEq(IERC20(IMD).balanceOf(INTAKE), collected + price);
        assertEq(IERC20(IMD).allowance(address(gate), INTAKE), 0);
    }
}

contract GateLaunchTest is GateLaunchFixture {
    function test_factoryDeploysOnlyGateWithAllFifteenManifestWords() public {
        bytes memory arguments = _arguments();
        assertEq(arguments.length, 15 * 32);
        bytes memory creation = _creation(arguments);
        bytes32 salt = keccak256("gate launch");
        address predicted = vm.computeCreate2Address(salt, keccak256(creation), address(factory));
        CabalGate gate = CabalGate(factory.deploy(creation, salt));
        assertEq(address(gate), predicted);
        assertEq(gate.owner(), launchOwner);
        assertNotEq(gate.owner(), address(factory));
        assertEq(address(gate.hook()), HOOK);
        assertEq(address(gate.cabal()), MockLaunchHook(HOOK).cabal());
        assertEq(address(gate.poolManager()), address(MockLaunchHook(HOOK).poolManager()));
        assertEq(gate.configVersion(), 1);
        assertEq(address(gate.estimator().poolManager()), address(gate.poolManager()));
        assertEq(abi.encode(gate.configuration()), abi.encode(_expectedConfig(address(gate))));
        assertEq(abi.encode(gate.configurationAt(1)), abi.encode(_expectedConfig(address(gate))));
        // The words describe the pool the hook reports; the hook owner should recompute this before binding,
        // because setGate compares only hook() and cabal() and a wrong key would be bound for good.
        assertEq(keccak256(abi.encode(_manifestKey())), keccak256(abi.encode(MockLaunchHook(HOOK).poolKey())));
        assertEq(gate.POOL_FEE(), MockLaunchHook(HOOK).poolKey().fee);
        assertEq(gate.POOL_TICK_SPACING(), MockLaunchHook(HOOK).poolKey().tickSpacing);
        // The existing hook remains unbound until its own owner performs the handoff.
        assertEq(MockLaunchHook(HOOK).gate(), address(0));
        _assertRuntime(address(gate));
        _assertRuntime(address(gate.questionBuilder()));
        _assertRuntime(address(gate.estimator()));
    }

    /// @dev The constructor sorts CABAL and IMD into currency0/currency1 itself. The live CABAL sorts below IMD;
    ///      with a CABAL above IMD the derived key must still be the one the hook reports, or no request could pass.
    function test_constructorSortsCurrenciesWhenCabalSortsAboveImd() public {
        address highCabal = address(type(uint160).max - 1);
        address highHook = makeAddr("hook of a CABAL above IMD");
        assertGt(uint160(highCabal), uint160(IMD));
        vm.etch(highCabal, IMD.code);
        deployCodeTo("GateLaunch.t.sol:MockLaunchHook", abi.encode(hookOwner, highCabal, IMD), highHook);
        PoolKey memory reported = MockLaunchHook(highHook).poolKey();
        assertEq(Currency.unwrap(reported.currency0), IMD);
        assertEq(Currency.unwrap(reported.currency1), highCabal);
        assertEq(keccak256(abi.encode(reported)), keccak256(abi.encode(_sortedKey(highCabal, IMD, highHook))));

        bytes memory arguments = _arguments();
        assembly ("memory-safe") {
            mstore(add(arguments, 32), highHook) // hook
            mstore(add(arguments, 96), highCabal) // cabal
        }
        CabalGate gate = CabalGate(factory.deploy(_creation(arguments), keccak256("sorted the other way")));
        assertEq(address(gate.hook()), highHook);
        assertEq(address(gate.cabal()), highCabal);
        _preparePoolFor(reported);
        address user = makeAddr("sorted user");
        _fund(user, gate, highCabal);
        _assertRefused(gate, user, true);
        vm.prank(hookOwner);
        MockLaunchHook(highHook).setGate(address(gate));
        _assertAccepted(gate, user, true);
        // A hook reporting the same tokens in the wrong order is not the pool the gate was built for.
        MockLaunchHook(highHook)
            .reportKey(PoolKey(Currency.wrap(highCabal), Currency.wrap(IMD), FEE, TICK_SPACING, IHooks(highHook)));
        address other = makeAddr("second sorted user");
        _fund(other, gate, highCabal);
        _assertRefused(gate, other, false);
    }

    function test_existingHookOwnerBindsGateOnceAndRefusesSecondGate() public {
        CabalGate gate = _deploy(keccak256("first gate"));
        CabalGate second = _deploy(keccak256("second gate"));
        vm.prank(launchOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, launchOwner));
        MockLaunchHook(HOOK).setGate(address(gate));
        vm.prank(hookOwner);
        MockLaunchHook(HOOK).setGate(address(gate));
        assertEq(MockLaunchHook(HOOK).gate(), address(gate));
        vm.prank(hookOwner);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        MockLaunchHook(HOOK).setGate(address(second));
        vm.prank(hookOwner);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        MockLaunchHook(HOOK).setGate(address(gate));
        assertEq(MockLaunchHook(HOOK).gate(), address(gate));
    }

    /// @dev Swapping the CABAL and IMD roles keeps the sorted key, so the constructor cannot tell; the hook can,
    ///      and refuses to bind such a gate, which then can never submit.
    function test_hookRefusesGateWithSwappedTokenRoles() public {
        bytes memory arguments = _arguments();
        assembly ("memory-safe") {
            mstore(add(arguments, 96), IMD) // cabal, word 2
            mstore(add(arguments, 192), CABAL) // imd, word 5
        }
        CabalGate swapped = CabalGate(factory.deploy(_creation(arguments), keccak256("swapped roles")));
        assertEq(address(swapped.cabal()), IMD);
        vm.prank(hookOwner);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        MockLaunchHook(HOOK).setGate(address(swapped));
        _preparePool();
        _fund(launchOwner, swapped);
        _assertRefused(swapped, launchOwner, true);
    }

    function test_requestSucceedsOnlyOnceTheHookReportsThisGate() public {
        CabalGate gate = _deploy(keccak256("bound gate"));
        _preparePool();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _fund(alice, gate);
        _fund(bob, gate);
        assertEq(MockLaunchHook(HOOK).gate(), address(0));
        _assertRefused(gate, alice, true);
        _assertRefused(gate, bob, false);
        vm.prank(hookOwner);
        MockLaunchHook(HOOK).setGate(address(gate));
        bytes32 buyId = _assertAccepted(gate, alice, true);
        bytes32 sellId = _assertAccepted(gate, bob, false);
        assertTrue(buyId != sellId);
        assertTrue(gate.getRequest(buyId).buy);
        assertFalse(gate.getRequest(sellId).buy);
        (address target,) = MockIntake(INTAKE).lastCallback();
        assertEq(target, address(gate));
        assertEq(MockIntake(INTAKE).lastAction(), ACTION);
        assertEq(MockIntake(INTAKE).lastToken(), IMD);
    }

    function test_requestRevertsWhenTheHookReportsAnotherKeyCabalImdOrGate() public {
        CabalGate gate = _deploy(keccak256("checked gate"));
        _preparePool();
        vm.prank(hookOwner);
        MockLaunchHook(HOOK).setGate(address(gate));
        address user = makeAddr("checked user");
        _fund(user, gate);
        MockLaunchHook mock = MockLaunchHook(HOOK);

        // Memory structs alias on assignment, so every wrong key is built fresh from the words.
        PoolKey memory wrong = _manifestKey();
        wrong.fee = 3000;
        mock.reportKey(wrong);
        _assertRefused(gate, user, true);
        wrong = _manifestKey();
        wrong.tickSpacing = 10;
        mock.reportKey(wrong);
        _assertRefused(gate, user, false);
        wrong = _manifestKey();
        wrong.hooks = IHooks(address(0));
        mock.reportKey(wrong);
        _assertRefused(gate, user, true);
        wrong = _manifestKey();
        (wrong.currency0, wrong.currency1) = (wrong.currency1, wrong.currency0);
        mock.reportKey(wrong);
        _assertRefused(gate, user, true);
        mock.reportKey(_manifestKey());

        mock.reportTokens(IMD, IMD); // wrong cabal, imd intact
        _assertRefused(gate, user, true);
        mock.reportTokens(CABAL, CABAL); // wrong imd, cabal intact
        _assertRefused(gate, user, false);
        mock.reportTokens(CABAL, IMD);

        mock.reportGate(address(0));
        _assertRefused(gate, user, true);
        mock.reportGate(makeAddr("another gate"));
        _assertRefused(gate, user, false);
        mock.reportGate(address(gate));

        // Every read matches the words again: the same user, same pool, same request now goes through.
        _assertAccepted(gate, user, true);
    }

    function test_explicitOwnerControlsConfigurationInsteadOfFactory() public {
        CabalGate gate = _deploy(keccak256("ownership"));
        CabalGate.Config memory cfg = gate.configuration();
        cfg.windowHours = 2;
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        gate.configure(cfg);
        vm.prank(launchOwner);
        gate.configure(cfg);
        assertEq(gate.configuration().windowHours, 2);
    }

    /// @dev The owner's reconfiguration runs on the live chain and keeps the checks the constructor cannot make.
    function test_ownerConfigureKeepsLiveDependencyChecksAndOracleBounds() public {
        CabalGate gate = _deploy(keccak256("live checks"));
        CabalGate.Config memory cfg = gate.configuration();
        vm.startPrank(launchOwner);
        cfg.intake = makeAddr("intake without code");
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        cfg = gate.configuration();
        cfg.imd = CABAL; // not what the hook reports as IMD
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        cfg = gate.configuration();
        vm.etch(IMD, "");
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        vm.etch(IMD, address(new MockERC20("Mock IMD", "IMD", 0)).code);
        // The oracle refuses panels outside 2..300, so the gate must not accept a configuration it cannot use.
        cfg.quorum = 1;
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        (cfg.panelSize, cfg.quorum) = (301, 300);
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        gate.configure(cfg);
        (cfg.panelSize, cfg.quorum) = (300, 300);
        gate.configure(cfg);
        (cfg.panelSize, cfg.quorum) = (2, 2);
        gate.configure(cfg);
        vm.stopPrank();
        assertEq(gate.configVersion(), 3);
        assertEq(gate.configuration().panelSize, 2);
    }

    function test_flatConstructorRetainsEveryValidation() public {
        // ABI word index, bad value: hook 0, poolManager 1, cabal 2, owner 3, intake 4, imd 5, signer 6,
        // action 7, maxBuy 8, maxSell 9, impact 10, drift 11, panel 12, quorum 13, window 14.
        uint256[25] memory indices =
            [uint256(0), 1, 2, 2, 4, 5, 5, 6, 7, 8, 9, 8, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 3, 3];
        uint256[25] memory values = [
            uint256(0),
            0,
            0,
            uint256(uint160(IMD)), // cabal == imd: no sorted pair
            0,
            0,
            uint256(uint160(CABAL)), // imd == cabal
            0,
            0,
            0,
            0,
            uint256(uint128(type(int128).max)) + 1,
            uint256(uint128(type(int128).max)) + 1,
            0,
            5001,
            299,
            5001,
            301,
            19, // panel below quorum
            1,
            31, // quorum above panel
            0,
            25,
            0, // zero owner
            uint256(uint160(POOL_MANAGER)) | (1 << 160) // dirty address word
        ];
        for (uint256 i; i < indices.length; ++i) {
            bytes memory arguments = _arguments();
            uint256 offset = indices[i] * 32;
            uint256 value = values[i];
            assembly ("memory-safe") {
                mstore(add(add(arguments, 32), offset), value)
            }
            bytes memory creation = _creation(arguments);
            vm.expectRevert("application constructor failed");
            factory.deploy(creation, bytes32(i));
        }
    }

    /// @dev The constructor needs nothing at the dependency addresses, before or after they have code.
    function test_constructorIgnoresDependencyCodeAndHookState() public {
        bytes memory creation = _creation(_arguments());
        MockLaunchHook(HOOK).reportTokens(INTAKE, INTAKE);
        MockLaunchHook(HOOK).reportGate(makeAddr("someone else's gate"));
        vm.mockCall(HOOK, abi.encodeWithSignature("initialized()"), abi.encode(false));
        assertGt(factory.deploy(creation, bytes32(uint256(1))).code.length, 0);
        vm.clearMockedCalls();
        address[4] memory dependencies = [HOOK, INTAKE, IMD, POOL_MANAGER];
        for (uint256 i; i < dependencies.length; ++i) {
            vm.etch(dependencies[i], "");
        }
        assertGt(factory.deploy(creation, bytes32(uint256(2))).code.length, 0);
    }
}
