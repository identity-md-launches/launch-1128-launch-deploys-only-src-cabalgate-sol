// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CabalFixture} from "./CabalFixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

/// @dev An Intake that does only what the live one does on submission: pull the price and return an id. The
///      fixture's MockIntake also keeps every body in storage, which would be charged to the gate here.
contract LeanIntake {
    uint256 public nonce;

    event Requested(bytes body);

    function priceOf(bytes32, address) external pure returns (uint256) {
        return 0.5 ether;
    }

    function request(bytes32, bytes calldata body, IIntake.Callback calldata, address token, uint256 price)
        external
        returns (bytes32)
    {
        require(IERC20(token).transferFrom(msg.sender, address(this), price));
        emit Requested(body);
        return keccak256(abi.encode(block.chainid, address(this), ++nonce));
    }
}

/// @notice Submission cost is dominated by the question blob and the request's storage, not by text scanning:
///         the reason is validated, counted and escaped in one pass, and nothing scans the fixed text.
contract SubmissionGasTest is CabalFixture {
    function setUp() public override {
        super.setUp();
        CabalGate.Config memory cfg = gate.configuration();
        cfg.intake = address(new LeanIntake());
        gate.configure(cfg);
        token.transfer(BOB, 1000 ether);
    }

    function test_shortBuyAndSellStayUnderBudget() public {
        vm.prank(ALICE);
        uint256 gas = gasleft();
        gate.submitBuyRequest(100 ether, "Pay October hosting");
        gas -= gasleft();
        assertLt(gas, 650_000, "buy submission");
        vm.prank(BOB);
        gas = gasleft();
        gate.submitSellRequest(500 ether, "Pay October hosting");
        gas -= gasleft();
        assertLt(gas, 750_000, "sell submission");
    }

    function test_longestReasonStaysUnderBudget() public {
        bytes memory reason = new bytes(280 * 4);
        for (uint256 i; i < 280; ++i) {
            reason[4 * i] = 0xf0;
            reason[4 * i + 1] = 0x9f;
            reason[4 * i + 2] = 0x98;
            reason[4 * i + 3] = 0x80;
        }
        vm.prank(ALICE);
        uint256 gas = gasleft();
        gate.submitBuyRequest(100 ether, string(reason));
        gas -= gasleft();
        assertLt(gas, 1_300_000, "longest buy submission");
    }
}
