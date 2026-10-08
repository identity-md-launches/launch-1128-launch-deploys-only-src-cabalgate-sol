// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CabalFixture} from "./CabalFixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Attestation} from "../src/interfaces/IIntake.sol";

contract OracleLatencyTest is CabalFixture {
    function test_deliveryJustBeforeOldExpiryRetainsFullApproval() public {
        _assertDelayedDelivery(899);
    }

    function test_deliveryAtOldExpiryRetainsFullApproval() public {
        _assertDelayedDelivery(900);
    }

    function test_deliveryJustBeforeRequestDeadlineRetainsFullApproval() public {
        _assertDelayedDelivery(3599);
    }

    // Use the requested validity and stored submission time, with an isolated fixture per delay.
    function _assertDelayedDelivery(uint256 delay) private {
        bytes32 id = submit(true, 100 ether);
        Attestation memory a = attestation(id, true);
        a.issuedAt = gate.getRequest(id).createdAt;
        uint256 validity = vm.parseJsonUint(string(intake.bodyOf(id)), ".validForSeconds");
        a.expiresAt = uint64(uint256(a.issuedAt) + validity);
        bytes memory signature = sign(a, ORACLE_KEY, address(gate));

        uint256 deliveredAt = uint256(a.issuedAt) + delay;
        vm.warp(deliveredAt);
        intake.deliver(gate, id, a, signature);
        CabalGate.Request memory request = gate.getRequest(id);
        assertEq(uint8(request.status), uint8(CabalGate.Status.Approved));
        assertEq(request.approvedUntil, deliveredAt + gate.APPROVAL_WINDOW());
        assertLe(request.approvedUntil, a.expiresAt);
        assertLe(validity, gate.MAX_VALIDITY());

        vm.warp(request.approvedUntil - 1);
        vm.prank(ALICE);
        assertGt(gate.executeBuyRequest(id, 1), 0);
        assertSettled();
    }
}
