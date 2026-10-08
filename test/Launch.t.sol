// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookSaltMiner} from "../script/HookSaltMiner.sol";
import {CabalFixture} from "./CabalFixture.sol";
import {CabalCoin} from "../src/CabalCoin.sol";
import {CabalHook} from "../src/CabalHook.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Stand-in for the network's launch factory: deploys the token, then the hook at a mined CREATE2 salt, then
///      initializes the pool, all in one call, exactly as the manifest's one-transaction launch does.
contract LaunchFactory {
    CabalCoin public token;
    CabalHook public hook;

    function launch(IPoolManager manager, bytes memory hookArguments, address imd, uint160 price)
        external
        returns (PoolKey memory key)
    {
        token = new CabalCoin();
        bytes memory creation = abi.encodePacked(type(CabalHook).creationCode, hookArguments);
        (bytes32 salt,) = HookSaltMiner.find(address(this), keccak256(creation), 0, 200000);
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(creation, 0x20), mload(creation), salt)
        }
        require(at != address(0), "hook deployment reverted");
        hook = CabalHook(at);
        (address c0, address c1) = address(token) < imd ? (address(token), imd) : (imd, address(token));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(at));
        manager.initialize(key, price);
        // The real factory keeps the supply for seeding and distribution; here the test seeds.
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
}

/// @notice Rehearses the launch with the arguments the manifest can express: `$poolManager`, an unspecified
///         owner written as 0xdead, and the IMD literal. The whole trading flow then runs on that deployment.
contract LaunchTest is CabalFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    LaunchFactory internal factory;

    function _launch(bool, uint160 price) internal override {
        factory = new LaunchFactory();
        key = factory.launch(manager, abi.encode(manager, DEAD, imd), address(imd), price);
        token = factory.token();
        hook = factory.hook();
    }

    function test_manifestArgumentsLaunchInOneTransaction() public view {
        assertTrue(hook.initialized());
        assertEq(hook.initializer(), address(factory));
        assertEq(hook.cabal(), address(token));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(uint160(address(hook)) & HookFlags.ALL, HookFlags.CABAL);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, Q96);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_unspecifiedOwnerIsTheLaunchOriginatorWhoBindsTheGate() public {
        assertEq(hook.launcher(), tx.origin);
        assertEq(hook.owner(), tx.origin);
        assertTrue(tx.origin != address(this) && tx.origin != address(factory));
        assertEq(hook.gate(), address(gate));
        // Binding happened once, from the owner; it cannot be repeated or done by anyone else.
        CabalGate another = new CabalGate(hook, address(this), defaultConfig());
        vm.prank(address(factory));
        vm.expectRevert();
        hook.setGate(address(another));
        vm.prank(tx.origin);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        hook.setGate(address(another));
        // Ownership moves on with the two-step transfer, as the launcher must do for the project's owner.
        vm.prank(tx.origin);
        hook.transferOwnership(BOB);
        assertEq(hook.owner(), tx.origin);
        vm.prank(BOB);
        hook.acceptOwnership();
        assertEq(hook.owner(), BOB);
    }

    function test_tradingWorksOnTheFactoryLaunchedPool() public {
        uint256 received = buy(100 ether);
        assertGt(received, 0);
        assertEq(imd.balanceOf(hook.DEAD()), 0.25 ether);
        bytes32 id = submit(false, received);
        approve(id);
        vm.prank(ALICE);
        assertGt(gate.executeSellRequest(id), 0);
        assertSettled();
    }

    function test_zeroOwnerFallsBackToTheOriginatorAndExplicitOwnerIsKept() public {
        bytes memory creation = abi.encodePacked(type(CabalHook).creationCode, abi.encode(manager, address(0), imd));
        (bytes32 salt,) = HookSaltMiner.find(address(this), keccak256(creation), 0, 200000);
        CabalHook zero = new CabalHook{salt: salt}(manager, address(0), imd);
        assertEq(zero.owner(), tx.origin);
        creation = abi.encodePacked(type(CabalHook).creationCode, abi.encode(manager, BOB, imd));
        (salt,) = HookSaltMiner.find(address(this), keccak256(creation), 0, 200000);
        CabalHook explicit = new CabalHook{salt: salt}(manager, BOB, imd);
        assertEq(explicit.owner(), BOB);
        assertEq(explicit.launcher(), tx.origin);
        // The originator, not the immediate deployer, is what an unspecified owner resolves to.
        creation = abi.encodePacked(type(CabalHook).creationCode, abi.encode(manager, DEAD, imd));
        (salt,) = HookSaltMiner.find(ALICE, keccak256(creation), 0, 200000);
        vm.prank(ALICE, BOB);
        CabalHook relayed = new CabalHook{salt: salt}(manager, DEAD, imd);
        assertEq(relayed.owner(), BOB);
        assertEq(relayed.launcher(), BOB);
    }

    function test_secondPoolThroughTheLaunchedHookIsRefused() public {
        PoolKey memory again = key;
        vm.expectRevert();
        manager.initialize(again, Q96);
        again.fee = 3000;
        vm.expectRevert();
        manager.initialize(again, Q96);
    }
}

contract ReverseOrderLaunchTest is LaunchTest {
    function setUp() public override {
        _setup(false, false);
    }
}
