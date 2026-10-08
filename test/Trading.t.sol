// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookSaltMiner} from "../script/HookSaltMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CabalFixture} from "./CabalFixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {CabalHook} from "../src/CabalHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Attestation} from "../src/interfaces/IIntake.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TradingTest is CabalFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Initialization is authenticated by the pool parameters and the one-pool binding, not by who calls:
    ///      the launch manifest cannot name the factory, and the factory initializes in the hook's own deployment
    ///      transaction, so nobody else can reach a fresh hook first.
    function test_initializationOnceByAnySenderWithLaunchParametersAndImmutablePairAfterBinding() public {
        bytes memory creation = abi.encodePacked(type(CabalHook).creationCode, abi.encode(manager, address(this), imd));
        // Same deployer and arguments as the fixture's hook: search past its salt range for a distinct address.
        (bytes32 salt,) = HookSaltMiner.find(address(this), keccak256(creation), 200000, 200000);
        CabalHook fresh = new CabalHook{salt: salt}(manager, address(this), imd);
        assertEq(fresh.owner(), address(this));
        vm.prank(ALICE);
        vm.expectRevert();
        fresh.setIMD(IERC20(address(token)));
        fresh.setIMD(IERC20(address(token)));
        assertEq(address(fresh.imd()), address(token));
        fresh.setIMD(imd);
        PoolKey memory newKey = key;
        newKey.hooks = IHooks(address(fresh));
        newKey.fee = 3000;
        vm.expectRevert();
        manager.initialize(newKey, Q96);
        newKey.fee = 12500;
        newKey.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(newKey, Q96);
        newKey.tickSpacing = 60;
        MockERC20 other = new MockERC20("Other", "OTH", 0);
        PoolKey memory withoutImd = _sortedKey(address(token), address(other), fresh);
        vm.expectRevert();
        manager.initialize(withoutImd, Q96);
        vm.prank(BOB);
        manager.initialize(newKey, Q96);
        assertTrue(fresh.initialized());
        assertEq(fresh.initializer(), BOB);
        assertEq(fresh.cabal(), address(token));
        // One pool only: a second IMD pool through the same hook is refused, as is re-initializing the first.
        PoolKey memory second = _sortedKey(address(imd), address(other), fresh);
        vm.expectRevert();
        manager.initialize(second, Q96);
        vm.expectRevert();
        manager.initialize(newKey, Q96);
        vm.expectRevert(CabalHook.InvalidPool.selector);
        fresh.setIMD(IERC20(address(token)));
        vm.prank(ALICE);
        vm.expectRevert();
        fresh.setGate(address(gate));
        vm.expectRevert(CabalHook.InvalidGate.selector);
        fresh.setGate(address(gate));
    }

    function _sortedKey(address a, address b, CabalHook hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(hooks)));
    }

    function test_transferThatReturnsSuccessWithoutPaymentRejected() public {
        vm.mockCall(
            address(imd),
            abi.encodeWithSelector(imd.transferFrom.selector, ALICE, address(gate), intake.price()),
            abi.encode(true)
        );
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.UnsupportedToken.selector);
        gate.submitBuyRequest(100 ether, "Fund research");
        assertEq(gate.activeRequest(ALICE), bytes32(0));
        assertEq(imd.balanceOf(address(intake)), 0);
    }

    function test_buyAndSellBurnFeesOwnLiquidityAndTrackBasis() public {
        uint256 balance = imd.balanceOf(ALICE);
        uint256 received = buy(100 ether);
        assertGt(received, 0);
        assertEq(token.balanceOf(ALICE), received);
        assertEq(imd.balanceOf(ALICE), balance - intake.price() - 100.5 ether);
        assertEq(imd.balanceOf(hook.DEAD()), 0.25 ether);
        assertEq(hook.totalPolAllocated(), 0.25 ether);
        (uint256 units, uint256 cost, uint64 first) = gate.holdings(ALICE);
        assertEq(units, received);
        assertEq(cost, 100.5 ether);
        assertEq(first, block.timestamp);
        _assertPolPosition();
        assertSettled();
        vm.warp(block.timestamp + 1 days);
        bytes32 sellId = submit(false, received / 2);
        string memory q = vm.parseJsonString(string(intake.lastBody()), ".question");
        assertTrue(bytes(q).length > 100);
        approve(sellId);
        uint256 burnt = hook.totalBurned();
        uint256 beforeSell = imd.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 net = gate.executeSellRequest(sellId);
        uint256 burned = hook.totalBurned() - burnt;
        uint256 gross = net + burned * 2;
        assertEq(burned, gross / 400);
        assertEq(imd.balanceOf(ALICE), beforeSell + net);
        assertEq(hook.totalPolAllocated(), hook.totalBurned());
        assertEq(imd.balanceOf(hook.DEAD()), hook.totalBurned());
        (uint256 remaining, uint256 basis, uint64 firstAfter) = gate.holdings(ALICE);
        assertEq(remaining, received - received / 2);
        assertEq(basis, cost - cost * (received / 2) / received);
        assertEq(firstAfter, first);
        assertSettled();
    }

    function test_factoryCanAddCollectFeesAndRemoveDespiteSwapGate() public {
        buy(100 ether);
        uint256 beforeIMD = imd.balanceOf(address(this));
        modify(LOWER, UPPER, 0);
        assertGt(imd.balanceOf(address(this)), beforeIMD);
        modify(LOWER, UPPER, 1 ether);
        modify(LOWER, UPPER, -int256(SEED_LIQUIDITY + 1 ether));
        assertSettled();
    }

    function test_swapsOutsideGateRevertBothWays() public {
        vm.expectRevert();
        this.directSwap(true);
        vm.expectRevert();
        this.directSwap(false);
    }

    function test_callbacksOnlyManagerAndPermissionsMatch() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertFalse(
            p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.beforeAddLiquidity || p.beforeRemoveLiquidity
        );
        assertEq(uint160(address(hook)) & HookFlags.ALL, HookFlags.CABAL);
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.beforeSwap(address(gate), key, SwapParams(true, -1 ether, Q96 / 2), "");
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.afterSwap(address(gate), key, SwapParams(true, -1 ether, Q96 / 2), BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.unlockCallback("");
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.finishSwap();
        vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
        gate.unlockCallback(abi.encode(bytes32(0)));
        vm.prank(address(manager));
        vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
        gate.unlockCallback(abi.encode(bytes32(0)));
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(int24(0), int24(60)));
    }

    function test_onePoolOneGateAndNoExactOutput() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, Q96);
        vm.expectRevert(CabalHook.InvalidGate.selector);
        hook.setGate(address(gate));
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.InvalidSwap.selector);
        hook.beforeSwap(address(gate), key, SwapParams(true, 1 ether, Q96 / 2), "");
        vm.prank(address(manager));
        vm.expectRevert(CabalHook.InvalidPool.selector);
        hook.beforeSwap(address(gate), other, SwapParams(true, -1 ether, Q96 / 2), "");
    }

    function test_executionRequiresRequesterCorrectSideApprovalAndOnce() public {
        bytes32 id = submit(true, 100 ether);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.executeBuyRequest(id);
        approve(id);
        vm.prank(BOB);
        vm.expectRevert(CabalGate.NotRequester.selector);
        gate.executeBuyRequest(id);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.executeSellRequest(id);
        vm.prank(ALICE);
        gate.executeBuyRequest(id);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidRequest.selector);
        gate.executeBuyRequest(id);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Executed));
    }

    function test_expiryAtFiveMinutesAndClear() public {
        bytes32 id = submit(true, 100 ether);
        approve(id);
        vm.warp(block.timestamp + 300);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Expired.selector);
        gate.executeBuyRequest(id);
        vm.prank(ALICE);
        gate.clearRequest(id);
        assertEq(gate.activeRequest(ALICE), bytes32(0));
    }

    function test_minOutputMandatoryAndFailedExecutionRollsBackAllTransfers() public {
        bytes32 id = submit(true, 100 ether);
        deliverTrue(id);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Slippage.selector);
        gate.executeBuyRequest(id);
        vm.prank(BOB);
        vm.expectRevert(CabalGate.NotRequester.selector);
        gate.setSlippageLimit(id, 1);
        vm.prank(ALICE);
        gate.setSlippageLimit(id, type(uint256).max);
        uint256 beforeBalance = imd.balanceOf(ALICE);
        uint256 managerBalance = imd.balanceOf(address(manager));
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Slippage.selector);
        gate.executeBuyRequest(id);
        assertEq(imd.balanceOf(ALICE), beforeBalance);
        assertEq(imd.balanceOf(address(manager)), managerBalance);
        assertEq(imd.balanceOf(hook.DEAD()), 0);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
        assertEq(gate.activeRequest(ALICE), id);
        assertSettled();
        vm.prank(ALICE);
        gate.setSlippageLimit(id, 1);
        vm.prank(ALICE);
        gate.executeBuyRequest(id);
    }

    function test_liquidityChangeCannotBypassActualImpactLimit() public {
        bytes32 id = submit(true, 1000 ether);
        approve(id);
        modify(LOWER, UPPER, -int256(SEED_LIQUIDITY - 10000 ether));
        vm.prank(ALICE);
        vm.expectRevert();
        gate.executeBuyRequest(id);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
        assertEq(hook.totalBurned(), 0);
    }

    function test_transferredHoldingsHaveUnknownBasisAndRecordsReconcile() public {
        token.transfer(ALICE, 100 ether);
        bytes32 id = submit(false, 100 ether);
        approve(id);
        vm.prank(ALICE);
        gate.executeSellRequest(id);
        (uint256 u, uint256 c, uint64 first) = gate.holdings(ALICE);
        assertEq(u, 0);
        assertEq(c, 0);
        assertEq(first, 0);
        uint256 received = buy(100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, received);
        id = submit(true, 100 ether);
        (u, c, first) = gate.holdings(ALICE);
        assertEq(u, 0);
        assertEq(c, 0);
        assertEq(first, 0);
    }

    function test_fullSaleClearsBasisAndWeightedBuys() public {
        uint256 firstBuy = buy(100 ether);
        uint256 secondBuy = buy(200 ether);
        (uint256 units, uint256 cost,) = gate.holdings(ALICE);
        assertEq(units, firstBuy + secondBuy);
        assertEq(cost, 301.5 ether);
        bytes32 id = submit(false, units);
        approve(id);
        vm.prank(ALICE);
        gate.executeSellRequest(id);
        (units, cost,) = gate.holdings(ALICE);
        assertEq(units, 0);
        assertEq(cost, 0);
        assertSettled();
    }

    function test_protocolPositionCannotBeWithdrawnAndCanCompound() public {
        buy(100 ether);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 grid = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) grid -= 60;
        bool imd0 = Currency.unwrap(key.currency0) == address(imd);
        int24 lower = imd0 ? grid + 60 : grid - 600;
        int24 upper = imd0 ? grid + 660 : grid;
        (uint128 beforeL,,) = manager.getPositionInfo(key.toId(), address(hook), lower, upper, 0);
        hook.compound(lower, upper);
        (uint128 afterL,,) = manager.getPositionInfo(key.toId(), address(hook), lower, upper, 0);
        assertGe(afterL, beforeL);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("withdraw(address,uint256)", ALICE, 1 ether));
        assertFalse(ok);
        assertSettled();
    }

    function test_runtimeSizeAndNoEscapeHatches() public view {
        assertLe(address(hook).code.length, 24576);
        assertLe(address(gate).code.length, 24576);
        bytes memory code = address(hook).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function testFuzz_roundTripAccounting(uint256 amount) public {
        amount = bound(amount, 1 ether, 1000 ether);
        uint256 received = buy(amount);
        bytes32 id = submit(false, received);
        approve(id);
        vm.prank(ALICE);
        gate.executeSellRequest(id);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(hook.totalBurned(), imd.balanceOf(hook.DEAD()));
        assertEq(hook.totalPolAllocated(), hook.totalBurned());
        assertSettled();
        assertEq(
            imd.totalSupply(),
            imd.balanceOf(address(this)) + imd.balanceOf(ALICE) + imd.balanceOf(BOB) + imd.balanceOf(address(manager))
                + imd.balanceOf(address(intake)) + imd.balanceOf(address(hook)) + imd.balanceOf(hook.DEAD())
        );
    }

    /// @dev Finding: with the seed withdrawn, only the hook's protocol-owned liquidity sits beside the current
    ///      tick. The estimate follows the swap into it instead of returning the 10000 sentinel, so submissions
    ///      stay possible, and the estimate tracks the movement the execution path then measures.
    function test_protocolOwnedLiquidityAloneKeepsSubmissionsOpen() public {
        uint256 received = buy(100 ether);
        modify(LOWER, UPPER, -int256(SEED_LIQUIDITY));
        assertEq(manager.getLiquidity(key.toId()), 0);
        uint256 sellAmount = received / 2000;
        uint256 estimate = gate.estimateImpact(false, sellAmount);
        assertGt(estimate, 0);
        assertLe(estimate, MAX_IMPACT);
        // A buy would push the price away from the POL: no liquidity in that direction, so it is refused honestly.
        assertEq(gate.estimateImpact(true, 1 ether), 10000);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.LimitExceeded.selector);
        gate.submitBuyRequest(1 ether, "Fund my community research for October");
        bytes32 id = submit(false, sellAmount);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Pending));
        approve(id);
        (uint160 before,,,) = manager.getSlot0(key.toId());
        vm.prank(ALICE);
        uint256 out = gate.executeSellRequest(id);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertGt(out, 0);
        uint256 actual = gate.priceMovement(before, afterPrice);
        assertApproxEqAbs(estimate, actual, 2);
        assertSettled();
    }

    function test_estimateMatchesExecutionWithActiveLiquidity() public {
        uint256 estimate = gate.estimateImpact(true, 1000 ether);
        bytes32 id = submit(true, 1000 ether);
        approve(id);
        (uint160 before,,,) = manager.getSlot0(key.toId());
        vm.prank(ALICE);
        gate.executeBuyRequest(id);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertApproxEqAbs(estimate, gate.priceMovement(before, afterPrice), 2);
        assertEq(gate.estimateImpact(true, type(uint128).max), 10000);
    }

    /// @dev Finding: other traders' approved executions move the price; drift is bounded by maxDriftBps, not by
    ///      the single-trade impact cap, so an approval for a small trade survives two full-size trades ahead of it.
    function test_driftFromOtherTradesDoesNotInvalidateApprovalUntilDriftCap() public {
        CabalGate.Config memory cfg = gate.configuration();
        cfg.maxBuyAmount = 1e24;
        gate.configure(cfg);
        address carol = address(0xCA201);
        imd.mint(carol, 1_000_000 ether);
        vm.prank(carol);
        imd.approve(address(gate), type(uint256).max);
        bytes32 idA = submit(true, 1000 ether);
        approve(idA);
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? BOB : carol;
            bytes32 id = submitAs(who, true, 140000 ether);
            approveFor(id, who);
            vm.prank(who);
            gate.executeBuyRequest(id);
        }
        (uint160 current,,,) = manager.getSlot0(key.toId());
        uint256 drift = gate.priceMovement(gate.getRequest(idA).sqrtPriceX96, current);
        assertGt(drift, MAX_IMPACT);
        assertLe(drift, MAX_DRIFT);
        vm.prank(ALICE);
        assertGt(gate.executeBuyRequest(idA), 0);
        // Past the drift cap the stale approval is refused: with the cap at the impact limit, two more trades
        // ahead of a new request move the price beyond it.
        cfg = gate.configuration();
        cfg.maxDriftBps = MAX_IMPACT;
        gate.configure(cfg);
        bytes32 idB = submitAs(BOB, true, 1000 ether);
        approveFor(idB, BOB);
        for (uint256 i; i < 2; ++i) {
            bytes32 id = submitAs(carol, true, 140000 ether);
            approveFor(id, carol);
            vm.prank(carol);
            gate.executeBuyRequest(id);
        }
        (current,,,) = manager.getSlot0(key.toId());
        assertGt(gate.priceMovement(gate.getRequest(idB).sqrtPriceX96, current), MAX_IMPACT);
        vm.prank(BOB);
        vm.expectRevert(CabalGate.LimitExceeded.selector);
        gate.executeBuyRequest(idB);
    }

    /// @dev Finding: the specified four entry points work without a separate setSlippageLimit call.
    function test_executeWithInlineMinimumNeedsNoSeparateCall() public {
        bytes32 id = submit(true, 100 ether);
        deliverTrue(id);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Slippage.selector);
        gate.executeBuyRequest(id, type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert(CabalGate.NotRequester.selector);
        gate.executeBuyRequest(id, 1);
        vm.prank(ALICE);
        uint256 received = gate.executeBuyRequest(id, 1);
        assertGt(received, 0);
        assertEq(gate.getRequest(id).minimumOutput, 1);
        bytes32 sellId = submit(false, received);
        deliverTrue(sellId);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Slippage.selector);
        gate.executeSellRequest(sellId);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Slippage.selector);
        gate.executeSellRequest(sellId, type(uint256).max);
        vm.prank(ALICE);
        assertGt(gate.executeSellRequest(sellId, 1), 0);
        assertSettled();
    }

    function _assertPolPosition() internal view {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 grid = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) grid -= 60;
        bool imd0 = Currency.unwrap(key.currency0) == address(imd);
        (uint128 liquidity,,) = manager.getPositionInfo(
            key.toId(), address(hook), imd0 ? grid + 60 : grid - 600, imd0 ? grid + 660 : grid, 0
        );
        assertGt(liquidity, 0);
        assertLe(imd.balanceOf(address(hook)), 1);
    }
}

contract ReverseOrderTradingTest is TradingTest {
    function setUp() public override {
        _setup(false, false);
    }
}

contract TokenOnlySeedTest is CabalFixture {
    function setUp() public virtual override {
        _setup(true, true);
    }

    function test_firstBuyOnFreshManagerWithOnlyCabalSeeded() public {
        assertEq(imd.balanceOf(address(manager)), 0);
        assertGt(buy(100 ether), 0);
        assertEq(hook.totalBurned(), 0.25 ether);
        assertSettled();
    }
}

contract ReverseTokenOnlySeedTest is TokenOnlySeedTest {
    function setUp() public override {
        _setup(false, true);
    }
}
