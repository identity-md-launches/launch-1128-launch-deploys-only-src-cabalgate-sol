// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookSaltMiner} from "../script/HookSaltMiner.sol";
import {CabalFixture} from "./CabalFixture.sol";
import {CabalHook} from "src/CabalHook.sol";
import {CabalGate} from "src/CabalGate.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A liquidity provider that is neither the test contract nor the gate: it seeds, claims fees, removes,
///      donates and attempts swaps through its own unlock, the way a factory or any LP router would.
contract LpRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), key, lower, upper, liquidity)), (BalanceDelta));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, amount0, amount1)), (BalanceDelta));
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(2), key, zeroForOne, amount)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        uint8 mode = abi.decode(data, (uint8));
        BalanceDelta delta;
        PoolKey memory key;
        if (mode == 0) {
            int24 lower;
            int24 upper;
            int256 liquidity;
            (, key, lower, upper, liquidity) = abi.decode(data, (uint8, PoolKey, int24, int24, int256));
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, 0), "");
        } else if (mode == 1) {
            uint256 amount0;
            uint256 amount1;
            (, key, amount0, amount1) = abi.decode(data, (uint8, PoolKey, uint256, uint256));
            delta = manager.donate(key, amount0, amount1, "");
        } else {
            bool zeroForOne;
            int256 amount;
            (, key, zeroForOne, amount) = abi.decode(data, (uint8, PoolKey, bool, int256));
            delta = manager.swap(
                key,
                SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount > 0) manager.take(currency, address(this), uint128(amount));
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount)));
            manager.settle();
        }
    }
}

/// @notice The revision dropped the factory check from `beforeInitialize` and made the hook owner fall back to
///         the launch originator. These tests pin what that policy admits and refuses, and the hook's fee state
///         machine around a swap.
contract HookBindingTest is CabalFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Distinct salt ranges keep fresh hooks away from the fixture's (0..200k) and Trading's (200k..400k).
    function _freshHook(uint256 saltStart) internal returns (CabalHook fresh) {
        bytes memory creation = abi.encodePacked(type(CabalHook).creationCode, abi.encode(manager, address(this), imd));
        (bytes32 salt,) = HookSaltMiner.find(address(this), keccak256(creation), saltStart, 200000);
        fresh = new CabalHook{salt: salt}(manager, address(this), imd);
        assertFalse(fresh.initialized());
    }

    function _sortedKey(address a, address b, CabalHook hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(hooks)));
    }

    function test_buySubmissionRequiresHookHandoffBeforeCharging() public {
        _assertSubmissionRequiresHandoff(true);
    }

    function test_sellSubmissionRequiresHookHandoffBeforeCharging() public {
        _assertSubmissionRequiresHandoff(false);
    }

    function _assertSubmissionRequiresHandoff(bool buyRequest) private {
        hook = _freshHook(400000);
        key = _sortedKey(address(imd), address(token), hook);
        manager.initialize(key, Q96);
        modify(LOWER, UPPER, int256(SEED_LIQUIDITY));
        gate = deployGate(hook);
        CabalGate intended = gate;
        CabalGate second = deployGate(hook);
        intake.setPrice(0.5 ether);
        token.transfer(ALICE, 1000 ether);
        vm.startPrank(ALICE);
        imd.approve(address(gate), type(uint256).max);
        token.approve(address(gate), type(uint256).max);
        imd.approve(address(second), type(uint256).max);
        token.approve(address(second), type(uint256).max);
        vm.stopPrank();

        assertTrue(hook.initialized());
        assertEq(hook.gate(), address(0));
        _assertSubmissionRefusedWithoutPayment(buyRequest);
        hook.setGate(address(intended));
        gate = second;
        _assertSubmissionRefusedWithoutPayment(buyRequest);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        hook.setGate(address(second));

        gate = intended;
        uint256 beforePayment = imd.balanceOf(ALICE);
        bytes32 id = submit(buyRequest, 100 ether);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
        assertEq(gate.activeRequest(ALICE), id);
        assertEq(imd.balanceOf(ALICE), beforePayment - 0.5 ether);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        approve(id);
        vm.prank(ALICE);
        uint256 output = buyRequest ? gate.executeBuyRequest(id) : gate.executeSellRequest(id);
        assertGt(output, 0);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Executed));
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        assertSettled();
    }

    function _assertSubmissionRefusedWithoutPayment(bool buyRequest) private {
        uint256 beforePayment = imd.balanceOf(ALICE);
        uint256 beforeCabal = token.balanceOf(ALICE);
        uint256 beforeAllowance = imd.allowance(ALICE, address(gate));
        vm.expectRevert(CabalGate.InvalidConfig.selector);
        submit(buyRequest, 100 ether);
        assertEq(imd.balanceOf(ALICE), beforePayment);
        assertEq(token.balanceOf(ALICE), beforeCabal);
        assertEq(imd.allowance(ALICE, address(gate)), beforeAllowance);
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertSettled();
    }

    /// @dev Trust assumption made visible. The hook binds the first pool with the launch parameters whoever
    ///      initializes it, because the manifest cannot name the factory; its safety rests on the factory deploying
    ///      the hook and initializing in one transaction (docs/DEPLOYMENT.md, test/Launch.t.sol). If a hook were
    ///      ever deployed without that atomicity, a third party could pair IMD with a token of their own first,
    ///      and the binding, the inferred CABAL and any gate built on it would be theirs for good.
    function test_firstValidPoolBindsTheHookSoDeploymentAndInitializationMustBeAtomic() public {
        CabalHook fresh = _freshHook(400000);
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 0);
        PoolKey memory rogueKey = _sortedKey(address(imd), address(rogue), fresh);
        vm.prank(ALICE);
        manager.initialize(rogueKey, Q96);
        assertTrue(fresh.initialized());
        assertEq(fresh.initializer(), ALICE);
        assertEq(fresh.cabal(), address(rogue));
        PoolKey memory intended = _sortedKey(address(imd), address(token), fresh);
        vm.expectRevert();
        manager.initialize(intended, Q96);
        vm.expectRevert(CabalHook.InvalidPool.selector);
        fresh.setIMD(IERC20(address(token)));
        CabalGate forRogue = deployGate(fresh);
        assertEq(address(forRogue.cabal()), address(rogue));
        vm.expectRevert(CabalHook.InvalidGate.selector);
        fresh.setGate(address(gate));
        fresh.setGate(address(forRogue));
        assertEq(fresh.gate(), address(forRogue));
    }

    function test_initializationRefusesNativeCurrencyMisorderedKeysAndKeysNamingAnotherHook() public {
        CabalHook fresh = _freshHook(400000);
        PoolKey memory native =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 12500, 60, IHooks(address(fresh)));
        vm.expectRevert();
        manager.initialize(native, Q96);
        assertFalse(fresh.initialized());
        // The manager never routes these keys to this hook; the checks are defence in depth and must still hold.
        PoolKey memory elsewhere = _sortedKey(address(imd), address(token), hook);
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), elsewhere, Q96);
        PoolKey memory sorted = _sortedKey(address(imd), address(token), fresh);
        PoolKey memory misordered = PoolKey(sorted.currency1, sorted.currency0, 12500, 60, IHooks(address(fresh)));
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), misordered, Q96);
        PoolKey memory same = PoolKey(sorted.currency0, sorted.currency0, 12500, 60, IHooks(address(fresh)));
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), same, Q96);
        assertFalse(fresh.initialized());
        assertEq(fresh.cabal(), address(0));
        manager.initialize(sorted, Q96);
        assertTrue(fresh.initialized());
        assertEq(fresh.initializer(), address(this));
    }

    /// @dev The brief: the hook must not block the factory's seeding, liquidity or fee claims, and only the gate
    ///      may swap. Both halves hold before a gate exists and after it is bound, for a provider that is neither.
    function test_liquidityDonationsAndFeeClaimsPassBeforeAndAfterBindingWhileSwapsNeverDo() public {
        CabalHook fresh = _freshHook(400000);
        PoolKey memory k = _sortedKey(address(imd), address(token), fresh);
        manager.initialize(k, Q96);
        LpRouter lp = new LpRouter(manager);
        imd.mint(address(lp), 1_000_000 ether);
        token.transfer(address(lp), 1_000_000 ether);
        uint256 lpImd = imd.balanceOf(address(lp));
        uint256 lpCabal = token.balanceOf(address(lp));
        lp.modify(k, LOWER, UPPER, 1_000_000 ether);
        lp.donate(k, 1 ether, 2 ether);
        BalanceDelta claimed = lp.modify(k, LOWER, UPPER, 0);
        assertGt(claimed.amount0(), 0, "fee claim before binding");
        assertGt(claimed.amount1(), 0, "fee claim before binding");
        vm.expectRevert();
        lp.swap(k, true, -1 ether);
        vm.expectRevert();
        lp.swap(k, false, -1 ether);
        CabalGate bound = deployGate(fresh);
        fresh.setGate(address(bound));
        lp.modify(k, LOWER, UPPER, 1 ether);
        lp.donate(k, 3 ether, 0);
        claimed = lp.modify(k, LOWER, UPPER, 0);
        assertGt(claimed.amount0() + claimed.amount1(), 0, "fee claim after binding");
        lp.modify(k, LOWER, UPPER, -int256(1_000_000 ether + 1 ether));
        assertEq(manager.getLiquidity(k.toId()), 0);
        vm.expectRevert();
        lp.swap(k, true, -1 ether);
        vm.expectRevert();
        lp.swap(k, false, -1 ether);
        // Everything the provider put in came back to it, minus only v4's own per-operation rounding.
        assertApproxEqAbs(imd.balanceOf(address(lp)), lpImd, 10);
        assertApproxEqAbs(token.balanceOf(address(lp)), lpCabal, 10);
        assertLe(imd.balanceOf(address(lp)), lpImd);
        assertLe(token.balanceOf(address(lp)), lpCabal);
        assertEq(manager.currencyDelta(address(lp), k.currency0), 0);
        assertEq(manager.currencyDelta(address(lp), k.currency1), 0);
    }

    /// @dev afterSwap arms the fee for one swap; until the gate settles it nothing else may swap or compound, and
    ///      only the gate may settle. A volume below 400 minor units owes nothing and clears the state unpaid.
    function test_feeStateMachineBlocksSwapsAndCompoundingUntilTheGateSettles() public {
        SwapParams memory params = SwapParams(true, -1 ether, Q96 / 2);
        bool imd0 = Currency.unwrap(key.currency0) == address(imd);
        BalanceDelta delta = imd0 ? toBalanceDelta(-399, 1000) : toBalanceDelta(1000, -399);
        vm.prank(address(manager));
        hook.afterSwap(address(gate), key, params, delta, "");
        assertTrue(hook.awaitingFee());
        assertEq(hook.feeBase(), 399);
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.FeeNotCompleted.selector);
        hook.beforeSwap(address(gate), key, params, "");
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.FeeNotCompleted.selector);
        hook.afterSwap(address(gate), key, params, delta, "");
        vm.expectRevert(CabalHook.InvalidSwap.selector);
        hook.compound(LOWER, UPPER);
        vm.prank(ALICE);
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.finishSwap();
        vm.prank(address(this));
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.finishSwap();
        uint256 deadBefore = imd.balanceOf(hook.DEAD());
        vm.prank(address(gate));
        vm.expectEmit(address(hook));
        emit CabalHook.FeePaid(399, 0, 0);
        assertEq(hook.finishSwap(), 0);
        assertFalse(hook.awaitingFee());
        assertEq(hook.feeBase(), 0);
        assertEq(hook.totalBurned(), 0);
        assertEq(hook.totalPolAllocated(), 0);
        assertEq(imd.balanceOf(hook.DEAD()), deadBefore);
        vm.prank(address(gate));
        vm.expectRevert(CabalHook.InvalidSwap.selector);
        hook.finishSwap();
        // The sell direction arms the fee from the positive IMD leg, and an exact-output swap is refused outright.
        delta = imd0 ? toBalanceDelta(200, -5) : toBalanceDelta(-5, 200);
        vm.prank(address(manager));
        hook.afterSwap(address(gate), key, params, delta, "");
        assertEq(hook.feeBase(), 200);
        vm.prank(address(gate));
        hook.finishSwap();
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.InvalidSwap.selector);
        hook.afterSwap(address(gate), key, SwapParams(true, 1 ether, Q96 / 2), delta, "");
        // afterSwap is just as caller-bound as beforeSwap: a sender other than the gate is refused there too.
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.afterSwap(ALICE, key, params, delta, "");
        assertFalse(hook.awaitingFee());
    }

    /// @dev compound is permissionless, so a stranger's arguments must not be able to move anything: a range the
    ///      hook holds no position in, an inverted range and a misaligned range all revert without a trace.
    function test_compoundOnARangeTheHookDoesNotOwnRevertsAndChangesNothing() public {
        buy(100 ether);
        bytes32 before = _hookState();
        vm.expectRevert();
        hook.compound(LOWER, UPPER);
        vm.expectRevert();
        hook.compound(600, 60);
        vm.expectRevert();
        hook.compound(-61, 61);
        vm.expectRevert();
        hook.compound(TickMath.MIN_TICK, TickMath.MAX_TICK);
        assertEq(_hookState(), before);
        assertSettled();
    }

    function _hookState() private view returns (bytes32) {
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        return keccak256(
            abi.encode(
                imd.balanceOf(address(hook)),
                token.balanceOf(address(hook)),
                imd.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                hook.totalBurned(),
                hook.totalPolAllocated(),
                manager.getLiquidity(key.toId()),
                price,
                tick
            )
        );
    }
}

contract ReverseOrderHookBindingTest is HookBindingTest {
    function setUp() public override {
        _setup(false, false);
    }
}
