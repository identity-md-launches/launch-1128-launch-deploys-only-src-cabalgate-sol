// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GateLaunchFixture, MockLaunchHook} from "../GateLaunch.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIntake} from "../mocks/MockIntake.sol";
import {CabalGate} from "src/CabalGate.sol";
import {Attestation} from "src/interfaces/IIntake.sol";
import {OracleSignature} from "src/libraries/OracleSignature.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Request custody/lifecycle campaign against the production gate and its own helpers.
/// Only external dependencies are mocked. No CabalHook, CabalCoin or pool is deployed here.
/// Trading/fee settlement remains covered by the existing real-PoolManager campaigns.
contract GateOnlyRequestHandler is Test {
    uint256 public constant SIGNING_KEY = 0xA77157;
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    CabalGate public immutable gate;
    MockIntake public immutable intake;
    MockERC20 public immutable imd;
    MockERC20 public immutable cabal;
    address[3] public actors;
    bytes32[] public ids;
    mapping(address => bytes32) public active;
    mapping(bytes32 => CabalGate.Status) public status;
    mapping(bytes32 => bytes32) public usedAttestation;
    uint256[3] public charged;
    uint256[3] public donatedImd;
    uint256[3] public donatedCabal;
    uint256 public submissions;
    uint256 public approvals;
    uint256 public rejections;
    uint256 public clears;
    uint256 public failures;
    uint64 public expectedVersion;
    mapping(uint64 => bytes32) public configHash;

    constructor(CabalGate gate_) {
        gate = gate_;
        CabalGate.Config memory cfg = gate_.configuration();
        intake = MockIntake(cfg.intake);
        imd = MockERC20(cfg.imd);
        cabal = MockERC20(address(gate_.cabal()));
        expectedVersion = gate_.configVersion();
        for (uint64 i = 1; i <= expectedVersion; ++i) {
            configHash[i] = keccak256(abi.encode(gate_.configurationAt(i)));
        }
        actors = [makeAddr("gate requester A"), makeAddr("gate requester B"), makeAddr("gate requester C")];
        for (uint256 i; i < 3; ++i) {
            imd.mint(actors[i], INITIAL_BALANCE);
            cabal.mint(actors[i], INITIAL_BALANCE);
            vm.prank(actors[i]);
            imd.approve(address(gate_), type(uint256).max);
        }
    }

    function request(uint256 actorSeed, uint256 amountSeed, uint256 priceSeed, bool buy) public {
        uint256 index = actorSeed % 3;
        address actor = actors[index];
        if (active[actor] != 0) return;
        uint256 price = bound(priceSeed, 0, 1 ether);
        uint256 amount = bound(amountSeed, 1, 1 ether);
        intake.setPrice(price);
        vm.prank(actor);
        bytes32 id = buy
            ? gate.submitBuyRequest(amount, "Pay the documented community hosting invoice")
            : gate.submitSellRequest(amount, "Pay the documented community hosting invoice");
        assertTrue(id != 0);
        assertEq(uint8(status[id]), uint8(CabalGate.Status.None), "intake id reused");
        assertEq(intake.observedAllowance(), price, "oracle allowance must equal the quote");
        ids.push(id);
        active[actor] = id;
        status[id] = CabalGate.Status.Pending;
        charged[index] += price;
        ++submissions;
    }

    function resolve(uint256 actorSeed, bool yes) public {
        bytes32 id = active[actors[actorSeed % 3]];
        if (id == 0 || status[id] != CabalGate.Status.Pending) return;
        CabalGate.Request memory r = gate.getRequest(id);
        if (block.timestamp >= r.deadline) return;
        Attestation memory a = attestation(id, yes);
        bytes memory signature = _sign(a);
        intake.deliver(gate, id, a, signature); // MockIntake enforces the live 200,000 gas stipend.
        usedAttestation[a.requestId] = id;
        if (yes) {
            status[id] = CabalGate.Status.Approved;
            assertEq(gate.getRequest(id).approvedUntil, block.timestamp + 300);
            ++approvals;
        } else {
            status[id] = CabalGate.Status.Rejected;
            active[r.requester] = 0;
            ++rejections;
        }
    }

    function clear(uint256 actorSeed) public {
        address actor = actors[actorSeed % 3];
        bytes32 id = active[actor];
        if (id == 0) return;
        CabalGate.Request memory r = gate.getRequest(id);
        uint256 expiry = status[id] == CabalGate.Status.Pending ? r.deadline : r.approvedUntil;
        if (r.version == expectedVersion && block.timestamp < expiry) return;
        vm.prank(actor);
        gate.clearRequest(id);
        status[id] = CabalGate.Status.Cleared;
        active[actor] = 0;
        ++clears;
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 3601));
        vm.roll(block.number + 1);
    }

    function donate(uint256 actorSeed, uint256 amountSeed, bool cabalAsset) public {
        uint256 index = actorSeed % 3;
        uint256 amount = bound(amountSeed, 0, 1 ether);
        vm.prank(actors[index]);
        if (cabalAsset) {
            cabal.transfer(address(gate), amount);
            donatedCabal[index] += amount;
        } else {
            imd.transfer(address(gate), amount);
            donatedImd[index] += amount;
        }
    }

    function reconfigure(uint8 hoursSeed) public {
        CabalGate.Config memory cfg = gate.configuration();
        cfg.windowHours = uint8(bound(hoursSeed, 1, 24));
        gate.configure(cfg);
        configHash[++expectedVersion] = keccak256(abi.encode(cfg));
    }

    function refuseUnauthorized(uint256 actorSeed) public {
        uint256 index = actorSeed % 3;
        address other = actors[(index + 1) % 3];
        CabalGate.Config memory cfg = gate.configuration();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        gate.configure(cfg);
        bytes32 id = active[actors[index]];
        if (id != 0) {
            vm.prank(other);
            vm.expectRevert(CabalGate.NotRequester.selector);
            gate.clearRequest(id);
            vm.prank(other);
            vm.expectRevert(CabalGate.NotRequester.selector);
            gate.setSlippageLimit(id, 1);
            vm.prank(other);
            vm.expectRevert(CabalGate.NotRequester.selector);
            gate.executeBuyRequest(id);
        }
        ++failures;
    }

    function refusePayment(uint256 actorSeed, uint8 modeSeed) public {
        address actor = actors[actorSeed % 3];
        if (active[actor] != 0) return;
        uint256 mode = modeSeed % 3;
        intake.setPrice(0.5 ether);
        uint256 nonce = intake.nonce();
        if (mode == 0) {
            intake.setFailure(true);
        } else if (mode == 1) {
            intake.setSkipPayment(true);
        } else {
            vm.prank(actor);
            imd.approve(address(gate), 0);
        }
        vm.prank(actor);
        if (mode == 0) {
            vm.expectRevert("intake failed");
        } else if (mode == 1) {
            vm.expectRevert(CabalGate.UnsupportedToken.selector);
        } else {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC20InsufficientAllowance(address,uint256,uint256)", address(gate), 0, 0.5 ether
                )
            );
        }
        gate.submitBuyRequest(1 ether, "Pay the documented community hosting invoice");
        intake.setFailure(false);
        intake.setSkipPayment(false);
        vm.prank(actor);
        imd.approve(address(gate), type(uint256).max);
        assertEq(intake.nonce(), nonce, "failed payment consumed an intake id");
        assertEq(gate.activeRequest(actor), bytes32(0));
        ++failures;
    }

    function refuseCallback(uint256 actorSeed, bool tamper) public {
        bytes32 id = active[actors[actorSeed % 3]];
        if (id == 0 || status[id] != CabalGate.Status.Pending) return;
        if (block.timestamp >= gate.getRequest(id).deadline) return;
        Attestation memory a = attestation(id, true);
        bytes memory signature = _sign(a);
        bytes32 beforeState = keccak256(abi.encode(gate.getRequest(id)));
        if (tamper) {
            a.figure = 1; // Otherwise valid signed attestation, with one signed field changed.
            vm.expectRevert(CabalGate.InvalidAttestation.selector);
            intake.deliver(gate, id, a, signature);
        } else {
            vm.prank(actors[(actorSeed % 3 + 1) % 3]);
            vm.expectRevert(CabalGate.UnauthorizedCallback.selector);
            gate.onOracleResult(id, a, signature);
        }
        assertEq(keccak256(abi.encode(gate.getRequest(id))), beforeState);
        assertEq(gate.attestationUsedBy(a.requestId), bytes32(0));
        ++failures;
    }

    // Drives complete paths so a campaign cannot succeed solely on pending/expired requests.
    function cycle(uint256 actorSeed, bool yes, bool buy) public {
        clear(actorSeed);
        if (active[actors[actorSeed % 3]] != 0) return;
        request(actorSeed, 1 ether, 0.5 ether, buy);
        resolve(actorSeed, yes);
        if (yes) {
            advance(300);
            clear(actorSeed);
        }
    }

    function attestation(bytes32 id, bool yes) public view returns (Attestation memory a) {
        CabalGate.Request memory r = gate.getRequest(id);
        CabalGate.Config memory cfg = gate.configurationAt(r.version);
        a.requestId = keccak256(abi.encode("independent oracle UUID", id));
        a.chainId = 1;
        a.fromBlock = uint64(block.number - 1);
        a.toBlock = uint64(block.number);
        a.questionHash = gate.questionBuilder().questionHash(gate.questionOf(id), a.fromBlock, a.toBlock);
        a.answerType = 0;
        a.answer = abi.encode(yes);
        a.blockHash = keccak256("mock observed block");
        a.panelJobId = keccak256(abi.encode("panel UUID", id));
        a.panelSize = cfg.panelSize;
        a.quorum = cfg.quorum;
        a.agreed = cfg.quorum;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 900);
    }

    function digest(Attestation calldata a) external view returns (bytes32) {
        return OracleSignature.digest(a, 1, address(gate));
    }

    function _sign(Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNING_KEY, this.digest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Independent ghosts constrain every actor, not merely the aggregate token supply.
    function checkAccounting() external view {
        uint256 totalPaid;
        uint256 totalImdDonated;
        uint256 totalCabalDonated;
        for (uint256 i; i < 3; ++i) {
            totalPaid += charged[i];
            totalImdDonated += donatedImd[i];
            totalCabalDonated += donatedCabal[i];
            assertEq(imd.balanceOf(actors[i]), INITIAL_BALANCE - charged[i] - donatedImd[i]);
            assertEq(cabal.balanceOf(actors[i]), INITIAL_BALANCE - donatedCabal[i]);
            (uint256 units, uint256 cost, uint64 firstBuy) = gate.holdings(actors[i]);
            assertEq(units, 0, "request/callback created traded holdings");
            assertEq(cost, 0);
            assertEq(firstBuy, 0);
        }
        assertEq(imd.balanceOf(address(intake)), totalPaid, "paid requests are neither escrowed nor refunded");
        assertEq(imd.balanceOf(address(gate)), totalImdDonated, "request spent or retained someone else's IMD");
        assertEq(cabal.balanceOf(address(gate)), totalCabalDonated, "callback moved CABAL");
        assertEq(imd.totalSupply(), INITIAL_BALANCE * 3);
        assertEq(cabal.totalSupply(), INITIAL_BALANCE * 3);
        assertEq(imd.allowance(address(gate), address(intake)), 0);
        assertEq(imd.allowance(address(gate), address(gate.hook())), 0);
    }

    function checkLifecycle() external view {
        for (uint256 i; i < 3; ++i) {
            assertEq(gate.activeRequest(actors[i]), active[actors[i]]);
        }
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            assertEq(uint8(gate.getRequest(id).status), uint8(status[id]), "illegal lifecycle transition");
            bytes32 oracleId = keccak256(abi.encode("independent oracle UUID", id));
            assertEq(gate.attestationUsedBy(oracleId), usedAttestation[oracleId]);
        }
        assertEq(gate.configVersion(), expectedVersion);
        for (uint64 version = 1; version <= expectedVersion; ++version) {
            assertEq(keccak256(abi.encode(gate.configurationAt(version))), configHash[version]);
        }
        assertEq(gate.configuration().oracleVerifier, address(gate));
        assertEq(gate.configuration().boolAnswerType, 0);
        assertEq(gate.owner(), address(this));
        assertEq(MockLaunchHook(address(gate.hook())).gate(), address(gate));
    }
}

contract GateOnlyRequestsInvariantTest is GateLaunchFixture {
    GateOnlyRequestHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        vm.roll(1000);
        // Etching runtime alone omits MockIntake's price and gas-limit initialization.
        deployCodeTo("MockIntake.sol:MockIntake", INTAKE);
        address cabal = MockLaunchHook(HOOK).cabal();
        vm.etch(cabal, IMD.code); // Existing CABAL is represented by a test ERC-20, never CabalCoin.
        PoolKey memory key = MockLaunchHook(HOOK).poolKey();
        bytes32 stateSlot = keccak256(abi.encode(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        address manager = address(MockLaunchHook(HOOK).poolManager());
        // Only the known pool's state can be read; a wrong key fails instead of receiving a generic answer.
        vm.mockCall(
            manager, abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(bytes32(uint256(1 << 96)))
        );
        vm.mockCall(
            manager,
            abi.encodeWithSignature("extsload(bytes32)", bytes32(uint256(stateSlot) + 3)),
            abi.encode(bytes32(uint256(10_000_000 ether)))
        );
        CabalGate gate = _deploy(keccak256("gate-only request campaign"));
        vm.prank(hookOwner);
        MockLaunchHook(HOOK).setGate(address(gate));
        CabalGate.Config memory cfg = gate.configuration();
        cfg.signer = vm.addr(0xA77157); // Local attester only; launch-address tests retain the real signer.
        vm.prank(launchOwner);
        gate.configure(cfg);
        handler = new GateOnlyRequestHandler(gate);
        vm.prank(launchOwner);
        gate.transferOwnership(address(handler));
        vm.prank(address(handler));
        gate.acceptOwnership();

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.resolve.selector;
        selectors[2] = handler.clear.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.reconfigure.selector;
        selectors[6] = handler.refuseUnauthorized.selector;
        selectors[7] = handler.refusePayment.selector;
        selectors[8] = handler.refuseCallback.selector;
        selectors[9] = handler.cycle.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gatePreservesDonationsAndChargesOnlyTheRequester() public view {
        handler.checkAccounting();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_requestStatesSnapshotsAndBindingRemainConsistent() public view {
        handler.checkLifecycle();
    }

    function test_handlerExercisesPaymentsFailuresBothAnswersAndClearing() public {
        handler.donate(0, 1 ether, false);
        handler.donate(1, 1 ether, true);
        handler.refusePayment(0, 0);
        handler.refusePayment(0, 1);
        handler.refusePayment(0, 2);
        handler.request(0, 1, 0, true);
        handler.refuseUnauthorized(0);
        handler.refuseCallback(0, false);
        handler.refuseCallback(0, true);
        handler.resolve(0, true);
        handler.advance(300);
        handler.clear(0);
        handler.cycle(1, false, false);
        handler.cycle(2, true, true);
        handler.request(0, 1 ether, 0.5 ether, false);
        handler.advance(3600);
        handler.clear(0);
        handler.request(1, 1 ether, 1 ether, true);
        handler.reconfigure(24);
        handler.clear(1);
        handler.checkAccounting();
        handler.checkLifecycle();
        assertEq(handler.submissions(), 5);
        assertEq(handler.approvals(), 2);
        assertEq(handler.rejections(), 1);
        assertEq(handler.clears(), 4);
        assertEq(handler.failures(), 6);
    }
}
