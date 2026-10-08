// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CabalFixture} from "../CabalFixture.sol";
import {CabalGate} from "src/CabalGate.sol";
import {Attestation} from "src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Real PoolManager and production contracts; only external IMD and Intake are mocks.
/// Ghosts are updated from successful user actions, never from the hook's fee counters.
contract CabalHandler is CabalFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant CAROL = address(0xCA401);
    address[3] public actors = [ALICE, BOB, CAROL];
    bytes32[] public ids;
    mapping(bytes32 => CabalGate.Status) public expectedStatus;
    mapping(address => bytes32) public expectedActive;
    uint256 public chargedOracle;
    uint256 public feeLeg;
    uint256 public donatedImdToGate;
    uint256 public donatedCabalToGate;
    uint256 public buys;
    uint256 public sells;
    uint256 public callbacks;
    uint256 public clears;
    uint256 public compounds;
    uint256 public failedExecutions;
    uint256 private initialImdSupply;

    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }
    Position[] private positions;
    mapping(bytes32 => uint256) private positionIndex;
    bytes32 private constant POL_EVENT = keccak256("ProtocolLiquidityAdded(int24,int24,uint128,address,uint256)");
    bytes32 private constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function initialize(bool imd0) external {
        _setup(imd0, false);
        imd.mint(CAROL, 1_000_000 ether);
        token.transfer(CAROL, 10_000 ether);
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            imd.approve(address(gate), type(uint256).max);
            token.approve(address(gate), type(uint256).max);
            vm.stopPrank();
        }
        initialImdSupply = imd.totalSupply();
    }

    function request(uint256 actorSeed, uint256 amountSeed, bool isBuy) public {
        address user = actors[actorSeed % 3];
        if (expectedActive[user] != 0) return;
        uint256 max = isBuy ? 1000 ether : _min(token.balanceOf(user), 1000 ether);
        if (max < 400) return;
        uint256 amount = bound(amountSeed, 400, max);
        uint256 beforeBalance = imd.balanceOf(user);
        vm.prank(user);
        bytes32 id = isBuy
            ? gate.submitBuyRequest(amount, "Pay the October community server bill")
            : gate.submitSellRequest(amount, "Pay the October community server bill");
        assertEq(imd.balanceOf(user), beforeBalance - intake.price(), "submission must charge only oracle price");
        chargedOracle += intake.price();
        assertEq(uint8(expectedStatus[id]), uint8(CabalGate.Status.None), "ID reuse");
        ids.push(id);
        expectedStatus[id] = CabalGate.Status.Pending;
        expectedActive[user] = id;
    }

    function resolve(uint256 actorSeed, bool yes) public {
        address user = actors[actorSeed % 3];
        bytes32 id = expectedActive[user];
        if (id == 0 || expectedStatus[id] != CabalGate.Status.Pending) return;
        CabalGate.Request memory r = gate.getRequest(id);
        if (block.timestamp >= r.deadline) return;
        Attestation memory a = attestation(id, yes);
        CabalGate.Config memory cfg = gate.configurationAt(r.version);
        bytes memory signature = sign(a, ORACLE_KEY, cfg.oracleVerifier);
        uint256 userImd = imd.balanceOf(user);
        uint256 userCabal = token.balanceOf(user);
        uint256 burned = hook.totalBurned();
        uint256 gasUsed = intake.deliverWithGas(gate, id, a, signature);
        assertLt(gasUsed, 200000);
        assertEq(imd.balanceOf(user), userImd);
        assertEq(token.balanceOf(user), userCabal);
        assertEq(hook.totalBurned(), burned, "oracle callback must not trade");
        expectedStatus[id] = yes ? CabalGate.Status.Approved : CabalGate.Status.Rejected;
        if (!yes) expectedActive[user] = 0;
        ++callbacks;
    }

    function execute(uint256 actorSeed) public {
        address user = actors[actorSeed % 3];
        bytes32 id = expectedActive[user];
        if (!_executable(id)) return;
        CabalGate.Request memory r = gate.getRequest(id);
        uint256 beforeImd = imd.balanceOf(user);
        uint256 beforeCabal = token.balanceOf(user);
        vm.prank(user);
        gate.setSlippageLimit(id, 1);
        vm.recordLogs();
        vm.prank(user);
        uint256 output = r.buy ? gate.executeBuyRequest(id) : gate.executeSellRequest(id);
        uint256 volume = _recordPositions();
        uint256 half = volume * 25 / 10000;
        if (r.buy) {
            assertEq(volume, r.amount);
            assertEq(imd.balanceOf(user), beforeImd - r.amount - half * 2);
            assertEq(token.balanceOf(user), beforeCabal + output);
            ++buys;
        } else {
            // The real PoolManager's swap delta supplies gross IMD output independently of hook counters.
            assertEq(output, volume - half * 2);
            assertEq(imd.balanceOf(user), beforeImd + output);
            assertEq(token.balanceOf(user), beforeCabal - r.amount);
            ++sells;
        }
        feeLeg += half;
        expectedStatus[id] = CabalGate.Status.Executed;
        expectedActive[user] = 0;
    }

    function rejectBadExecution(uint256 actorSeed) external {
        address user = actors[actorSeed % 3];
        bytes32 id = expectedActive[user];
        if (id == 0) return;
        address other = actors[(actorSeed % 3 + 1) % 3];
        vm.prank(other);
        vm.expectRevert(CabalGate.NotRequester.selector);
        gate.executeBuyRequest(id);
        CabalGate.Request memory r = gate.getRequest(id);
        if (
            expectedStatus[id] == CabalGate.Status.Approved && r.version == gate.configVersion()
                && block.timestamp < r.approvedUntil
        ) {
            (uint160 current,,,) = manager.getSlot0(key.toId());
            if (gate.priceMovement(r.sqrtPriceX96, current) > gate.configurationAt(r.version).maxDriftBps) {
                bytes32 driftedState = _economicState(user, id);
                vm.prank(user);
                vm.expectRevert(CabalGate.LimitExceeded.selector);
                if (r.buy) gate.executeBuyRequest(id, 1);
                else gate.executeSellRequest(id, 1);
                assertEq(_economicState(user, id), driftedState, "refused drifted execution changed accounting");
                ++failedExecutions;
            }
        }
        if (!_executable(id)) return;
        vm.prank(user);
        gate.setSlippageLimit(id, type(uint256).max);
        bytes32 beforeState = _economicState(user, id);
        vm.prank(user);
        vm.expectRevert(CabalGate.Slippage.selector);
        if (r.buy) gate.executeBuyRequest(id);
        else gate.executeSellRequest(id);
        assertEq(_economicState(user, id), beforeState, "reverted execution changed accounting");
        ++failedExecutions;
    }

    function clear(uint256 actorSeed) public {
        address user = actors[actorSeed % 3];
        bytes32 id = expectedActive[user];
        if (id == 0) return;
        CabalGate.Request memory r = gate.getRequest(id);
        bool expired =
            r.status == CabalGate.Status.Pending ? block.timestamp >= r.deadline : block.timestamp >= r.approvedUntil;
        if (!expired && r.version == gate.configVersion()) return;
        vm.prank(user);
        gate.clearRequest(id);
        expectedActive[user] = 0;
        expectedStatus[id] = CabalGate.Status.Cleared;
        ++clears;
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 3601));
        vm.roll(block.number + 1);
    }

    function reconfigure(uint8 window) external {
        CabalGate.Config memory cfg = gate.configuration();
        cfg.windowHours = uint8(bound(window, 1, 24));
        gate.configure(cfg);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        token.transfer(to, amount);
        assertEq(token.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    function donate(uint256 actorSeed, uint256 amountSeed, bool cabalAsset, bool toGate) external {
        address user = actors[actorSeed % 3];
        IERC20 asset = cabalAsset ? IERC20(address(token)) : IERC20(address(imd));
        uint256 amount = bound(amountSeed, 0, _min(asset.balanceOf(user), 1 ether));
        vm.prank(user);
        asset.transfer(toGate ? address(gate) : address(hook), amount);
        if (toGate) {
            if (cabalAsset) donatedCabalToGate += amount;
            else donatedImdToGate += amount;
        }
    }

    function compound(uint256 positionSeed) external {
        if (positions.length == 0) return;
        Position memory p = positions[positionSeed % positions.length];
        uint256 balanceBefore = imd.balanceOf(address(this));
        vm.recordLogs();
        hook.compound(p.lower, p.upper);
        _recordPositions();
        assertEq(imd.balanceOf(address(this)), balanceBefore, "permissionless caller received POL");
        ++compounds;
    }

    // Atomic valid flows prevent a state-machine campaign from passing without executing trades.
    function trade(uint256 actorSeed, uint256 amountSeed, bool isBuy) external {
        clear(actorSeed);
        if (expectedActive[actors[actorSeed % 3]] != 0) return;
        request(actorSeed, amountSeed, isBuy);
        resolve(actorSeed, true);
        execute(actorSeed);
    }

    function checkInvariants() external view {
        assertEq(token.totalSupply(), 1_000_000_000 ether, "CABAL launch supply changed");
        assertEq(imd.totalSupply(), initialImdSupply);
        assertEq(_sum(IERC20(address(token))), token.totalSupply(), "CABAL conservation");
        assertEq(_sum(IERC20(address(imd))), initialImdSupply, "IMD conservation");
        assertEq(imd.balanceOf(address(intake)), chargedOracle, "oracle price conservation");
        assertEq(imd.balanceOf(address(gate)), donatedImdToGate, "gate retained or spent other people's IMD");
        assertEq(token.balanceOf(address(gate)), donatedCabalToGate, "gate retained or spent other people's CABAL");
        assertEq(imd.balanceOf(hook.DEAD()), feeLeg, "burn leg differs from trade volumes");
        assertEq(hook.totalBurned(), feeLeg);
        assertEq(hook.totalPolAllocated(), feeLeg);
        assertFalse(hook.awaitingFee());
        assertEq(hook.feeBase(), 0);
        assertEq(imd.allowance(address(gate), address(intake)), 0);
        assertEq(imd.allowance(address(gate), address(hook)), 0);
        assertEq(manager.currencyDelta(address(gate), key.currency0), 0);
        assertEq(manager.currencyDelta(address(gate), key.currency1), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(gate.activeRequest(actors[i]), expectedActive[actors[i]]);
            (uint256 units, uint256 cost, uint64 firstBuy) = gate.holdings(actors[i]);
            if (units == 0) {
                assertEq(cost, 0);
                assertEq(firstBuy, 0);
            }
        }
        for (uint256 i; i < ids.length; ++i) {
            assertEq(
                uint8(gate.getRequest(ids[i]).status), uint8(expectedStatus[ids[i]]), "illegal lifecycle transition"
            );
        }
        for (uint256 i; i < positions.length; ++i) {
            Position memory p = positions[i];
            (uint128 actual,,) = manager.getPositionInfo(key.toId(), address(hook), p.lower, p.upper, 0);
            assertEq(actual, p.liquidity, "POL principal disappeared or was never deposited");
        }
    }

    function _recordPositions() private returns (uint256 imdVolume) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                int256 amount = Currency.unwrap(key.currency0) == address(imd) ? int256(amount0) : int256(amount1);
                imdVolume = uint256(amount < 0 ? -amount : amount);
            }
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != POL_EVENT) continue;
            (int24 lower, int24 upper, uint128 liquidity,,) =
                abi.decode(logs[i].data, (int24, int24, uint128, address, uint256));
            bytes32 hash = keccak256(abi.encode(lower, upper));
            uint256 index = positionIndex[hash];
            if (index == 0) {
                positions.push(Position(lower, upper, liquidity));
                positionIndex[hash] = positions.length;
            } else {
                positions[index - 1].liquidity += liquidity;
            }
        }
    }

    function _executable(bytes32 id) private view returns (bool) {
        if (id == 0 || expectedStatus[id] != CabalGate.Status.Approved) return false;
        CabalGate.Request memory r = gate.getRequest(id);
        // Other actors' trades move the price between submission and execution; past the drift cap the gate
        // refuses, which rejectBadExecution asserts explicitly, so a silent skip here is not a hidden revert.
        (uint160 current,,,) = manager.getSlot0(key.toId());
        bool drifted = gate.priceMovement(r.sqrtPriceX96, current) > gate.configurationAt(r.version).maxDriftBps;
        return r.version == gate.configVersion() && block.timestamp < r.approvedUntil && !drifted
            && (r.buy || token.balanceOf(r.requester) >= r.amount);
    }

    function _economicState(address user, bytes32 id) private view returns (bytes32) {
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (uint256 units, uint256 cost, uint64 first) = gate.holdings(user);
        return keccak256(
            abi.encode(
                gate.getRequest(id),
                gate.activeRequest(user),
                imd.balanceOf(user),
                token.balanceOf(user),
                imd.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                imd.balanceOf(address(hook)),
                token.balanceOf(address(hook)),
                hook.totalBurned(),
                hook.totalPolAllocated(),
                hook.awaitingFee(),
                price,
                tick,
                units,
                cost,
                first
            )
        );
    }

    function _sum(IERC20 asset) private view returns (uint256 total) {
        total = asset.balanceOf(address(this)) + asset.balanceOf(address(manager)) + asset.balanceOf(address(hook))
            + asset.balanceOf(address(gate)) + asset.balanceOf(address(intake)) + asset.balanceOf(hook.DEAD());
        for (uint256 i; i < actors.length; ++i) {
            total += asset.balanceOf(actors[i]);
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
