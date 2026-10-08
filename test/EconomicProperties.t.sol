// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CabalFixture} from "./CabalFixture.sol";
import {CabalGate} from "src/CabalGate.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract EconomicPropertiesTest is CabalFixture {
    using StateLibrary for IPoolManager;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeCannotExceedHalfPercentAndRoundingIsBounded(uint256 volume) public view {
        uint256 fee = hook.feeFor(volume);
        assertLe(fee, volume / 200);
        assertLe(volume / 200 - fee, 1, "each 25bp leg loses less than one unit");
        assertEq(fee % 2, 0, "equal burn and POL legs");
        if (volume <= type(uint256).max - 400) assertEq(hook.feeFor(volume + 400), fee + 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_priceMovementSymmetricMonotoneAndBounded(uint160 a, uint160 b, uint160 c) public view {
        a = uint160(bound(a, 1, type(uint160).max));
        b = uint160(bound(b, a, type(uint160).max));
        c = uint160(bound(c, b, type(uint160).max));
        assertEq(gate.priceMovement(a, a), 0);
        assertEq(gate.priceMovement(a, b), gate.priceMovement(b, a));
        assertLe(gate.priceMovement(a, b), gate.priceMovement(a, c));
        assertLe(gate.priceMovement(a, c), 10000);
    }

    function test_feeAndPriceKnownBoundaries() public view {
        assertEq(hook.feeFor(0), 0);
        assertEq(hook.feeFor(1), 0);
        assertEq(hook.feeFor(399), 0);
        assertEq(hook.feeFor(400), 2);
        assertEq(hook.feeFor(401), 2);
        assertEq(hook.feeFor(type(uint256).max), (type(uint256).max / 400) * 2);
        assertEq(gate.priceMovement(Q96, Q96 * 2), 7500);
        assertEq(gate.priceMovement(Q96, Q96 / 2), 7500);
    }

    function test_realTradesAtFeeRoundingEdges() public {
        uint256[6] memory amounts = [uint256(398), 399, 400, 401, 799, 800];
        uint256 expectedBurn;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 beforeBalance = imd.balanceOf(ALICE);
            uint256 output = buy(amounts[i]);
            uint256 half = amounts[i] * 25 / 10000;
            expectedBurn += half;
            assertGt(output, 0);
            assertEq(imd.balanceOf(ALICE), beforeBalance - intake.price() - amounts[i] - half * 2);
            assertEq(imd.balanceOf(hook.DEAD()), expectedBurn);
            assertEq(hook.totalPolAllocated(), expectedBurn);
            assertSettled();
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_repeatedBuySellCannotCreateImd(uint256 amountSeed, uint8 cyclesSeed) public {
        uint256 amount = bound(amountSeed, 1000, 1000 ether);
        uint256 cycles = bound(cyclesSeed, 1, 3);
        uint256 starting = imd.balanceOf(ALICE);
        for (uint256 i; i < cycles; ++i) {
            uint256 beforeBalance = imd.balanceOf(ALICE);
            uint256 output = buy(amount);
            bytes32 sell = submit(false, output);
            approve(sell);
            vm.prank(ALICE);
            gate.executeSellRequest(sell);
            assertLt(imd.balanceOf(ALICE), beforeBalance, "round trip minted purchasing power");
            assertEq(token.balanceOf(ALICE), 0);
            (uint256 units, uint256 cost, uint64 first) = gate.holdings(ALICE);
            assertEq(units, 0);
            assertEq(cost, 0);
            assertEq(first, 0);
            assertSettled();
        }
        assertLe(imd.balanceOf(ALICE), starting - 2 * cycles * intake.price());
    }

    function test_insufficientExecutionAllowancePreservesApprovalAndCanRetry() public {
        bytes32 id = submit(true, 100 ether);
        approve(id);
        vm.prank(ALICE);
        imd.approve(address(gate), 100 ether); // Pool input alone omits the hook fee.
        uint256 beforeBalance = imd.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(gate), 100 ether, 100.5 ether
            )
        );
        gate.executeBuyRequest(id);
        assertEq(imd.balanceOf(ALICE), beforeBalance);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
        assertEq(gate.activeRequest(ALICE), id);
        assertSettled();
        vm.prank(ALICE);
        imd.approve(address(gate), 100.5 ether);
        vm.prank(ALICE);
        assertGt(gate.executeBuyRequest(id), 0);
        assertSettled();
    }

    function test_sellSlippageFailureRollsBackFeePositionAndCostBasis() public {
        uint256 acquired = buy(100 ether);
        bytes32 id = submit(false, acquired);
        approve(id);
        vm.prank(ALICE);
        gate.setSlippageLimit(id, type(uint256).max);
        uint256 burned = hook.totalBurned();
        uint256 beforeImd = imd.balanceOf(ALICE);
        (uint256 units, uint256 basis, uint64 first) = gate.holdings(ALICE);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Slippage.selector);
        gate.executeSellRequest(id);
        assertEq(hook.totalBurned(), burned);
        assertEq(hook.totalPolAllocated(), burned);
        assertEq(imd.balanceOf(ALICE), beforeImd);
        assertEq(token.balanceOf(ALICE), acquired);
        (uint256 unitsAfter, uint256 basisAfter, uint64 firstAfter) = gate.holdings(ALICE);
        assertEq(unitsAfter, units);
        assertEq(basisAfter, basis);
        assertEq(firstAfter, first);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, price);
        assertEq(uint8(gate.getRequest(id).status), uint8(CabalGate.Status.Approved));
        assertSettled();
        vm.prank(ALICE);
        gate.setSlippageLimit(id, 1);
        vm.prank(ALICE);
        assertGt(gate.executeSellRequest(id), 0);
        assertSettled();
    }
}
