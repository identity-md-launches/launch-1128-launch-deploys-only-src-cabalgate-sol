// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CabalHandler} from "./CabalHandler.sol";

abstract contract CabalInvariantBase is Test {
    CabalHandler internal handler;

    function setupCampaign(bool imd0) internal {
        handler = new CabalHandler();
        handler.initialize(imd0);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.resolve.selector;
        selectors[2] = handler.execute.selector;
        selectors[3] = handler.clear.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.transfer.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.compound.selector;
        selectors[8] = handler.rejectBadExecution.selector;
        selectors[9] = handler.reconfigure.selector;
        selectors[10] = handler.trade.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function test_handlerExercisesSuccessFailureExpiryAndCompounding() public {
        handler.trade(0, 100 ether, true);
        handler.request(0, 10 ether, false);
        handler.resolve(0, true);
        handler.rejectBadExecution(0);
        handler.execute(0);
        handler.compound(0);
        handler.request(1, 10 ether, true);
        handler.advance(3601);
        handler.clear(1);
        handler.request(1, 10 ether, true);
        handler.resolve(1, false);
        handler.checkInvariants();
        assertGt(handler.buys(), 0);
        assertGt(handler.sells(), 0);
        assertGt(handler.compounds(), 0);
        assertGt(handler.callbacks(), 0);
        assertGt(handler.failedExecutions(), 0);
        assertGt(handler.clears(), 0);
    }
}

contract CabalInvariantTest is CabalInvariantBase {
    function setUp() public {
        setupCampaign(true);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationSettlementLifecycleAndLockedPol() public view {
        handler.checkInvariants();
    }
}

contract CabalReverseInvariantTest is CabalInvariantBase {
    function setUp() public {
        setupCampaign(false);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationSettlementLifecycleAndLockedPol() public view {
        handler.checkInvariants();
    }
}
