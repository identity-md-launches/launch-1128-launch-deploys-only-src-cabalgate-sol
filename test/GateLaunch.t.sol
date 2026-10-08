// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {CabalHook} from "../src/CabalHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Models the existing hook's getters and owner-only, one-time binding; no pool or token launch.
contract MockLaunchHook {
    address public immutable owner;
    address public gate;
    address public constant cabal = 0x450e5910DEcEe15c3AC056E3ed66Cb5ea3Dd33BE;
    IERC20 public constant imd = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    IPoolManager public constant poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    constructor(address owner_) {
        owner = owner_;
    }

    function initialized() external pure returns (bool) {
        return true;
    }

    function poolKey() external view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(cabal), Currency.wrap(address(imd)), 12500, 60, IHooks(address(this)));
    }

    function setGate(address candidate) external {
        if (msg.sender != owner) revert Ownable.OwnableUnauthorizedAccount(msg.sender);
        if (
            gate != address(0) || candidate.code.length == 0 || address(CabalGate(candidate).hook()) != address(this)
                || address(CabalGate(candidate).cabal()) != cabal
        ) revert CabalHook.InvalidGate();
        gate = candidate;
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

contract GateLaunchTest is Test {
    address internal constant HOOK = 0xf41B6Ff942a082C0d320a0C151310ac2A922a0c0;
    address internal constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 internal constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    address internal launchOwner;
    address internal hookOwner;
    GateLaunchFactory internal factory;

    function setUp() public {
        vm.chainId(1);
        launchOwner = makeAddr("launch owner resolves $owner");
        hookOwner = makeAddr("existing hook owner");
        vm.etch(HOOK, address(new MockLaunchHook(hookOwner)).code);
        vm.etch(INTAKE, address(new MockIntake()).code);
        vm.etch(IMD, address(new MockERC20("Mock IMD", "IMD", 0)).code);
        factory = new GateLaunchFactory();
    }

    function _arguments() internal view returns (bytes memory) {
        return abi.encode(
            HOOK,
            launchOwner,
            INTAKE,
            IMD,
            SIGNER,
            ACTION,
            uint128(1e24),
            uint128(1e25),
            uint16(300),
            uint16(500),
            uint16(30),
            uint16(20),
            uint8(1)
        );
    }

    function _creation(bytes memory arguments) internal view returns (bytes memory) {
        return bytes.concat(vm.getCode("CabalGate.sol:CabalGate"), arguments);
    }

    function _deploy(bytes32 salt) internal returns (CabalGate) {
        return CabalGate(factory.deploy(_creation(_arguments()), salt));
    }

    function test_factoryDeploysOnlyGateWithAllThirteenManifestWords() public {
        bytes memory arguments = _arguments();
        assertEq(arguments.length, 13 * 32);
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

        CabalGate.Config memory expected =
            CabalGate.Config(INTAKE, IMD, SIGNER, address(gate), ACTION, 1e24, 1e25, 300, 500, 30, 20, 1, 0);
        assertEq(abi.encode(gate.configuration()), abi.encode(expected));
        assertEq(abi.encode(gate.configurationAt(1)), abi.encode(expected));
        // The existing hook remains unbound until its own owner performs the handoff.
        assertEq(MockLaunchHook(HOOK).gate(), address(0));
        _assertRuntime(address(gate));
        _assertRuntime(address(gate.questionBuilder()));
        _assertRuntime(address(gate.estimator()));
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
        assertEq(MockLaunchHook(HOOK).gate(), address(gate));
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

    function test_flatConstructorRetainsEveryConfigurationValidation() public {
        // ABI word indices and bad values cover the existing _configure boundaries.
        uint256[19] memory indices = [uint256(2), 2, 3, 3, 4, 5, 6, 7, 6, 7, 8, 8, 9, 9, 10, 11, 11, 12, 12];
        uint256[19] memory values = [
            uint256(0),
            uint256(uint160(launchOwner)),
            uint256(uint160(INTAKE)),
            0,
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
            1001,
            0,
            31,
            0,
            25
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

    function test_constructorRequiresHookInitializedAndDependencyCode() public {
        bytes memory creation = _creation(_arguments());
        vm.mockCall(HOOK, abi.encodeWithSelector(MockLaunchHook.initialized.selector), abi.encode(false));
        vm.expectRevert("application constructor failed");
        factory.deploy(creation, bytes32(0));
        vm.clearMockedCalls();
        address[3] memory dependencies = [HOOK, INTAKE, IMD];
        for (uint256 i; i < dependencies.length; ++i) {
            bytes memory runtime = dependencies[i].code;
            vm.etch(dependencies[i], "");
            vm.expectRevert("application constructor failed");
            factory.deploy(creation, bytes32(i));
            vm.etch(dependencies[i], runtime);
        }
        assertGt(factory.deploy(creation, bytes32(0)).code.length, 0);
    }

    function test_constructorRejectsZeroOwner() public {
        bytes memory arguments = _arguments();
        assembly ("memory-safe") {
            mstore(add(arguments, 64), 0)
        }
        bytes memory creation = _creation(arguments);
        vm.expectRevert("application constructor failed");
        factory.deploy(creation, bytes32(0));
    }

    function _assertRuntime(address application) private view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
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
