// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookSaltMiner} from "../script/HookSaltMiner.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CabalCoin} from "../src/CabalCoin.sol";
import {CabalHook} from "../src/CabalHook.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Attestation} from "../src/interfaces/IIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

abstract contract CabalFixture is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    uint256 internal constant ORACLE_KEY = 0x123456;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint160 internal constant Q96 = 1 << 96;
    int24 internal constant LOWER = -1200;
    int24 internal constant UPPER = 1200;
    uint256 internal constant SEED_LIQUIDITY = 10_000_000 ether;
    uint16 internal constant MAX_IMPACT = 500;
    uint16 internal constant MAX_DRIFT = 1500;
    // Published by the live service (GET /oracle/requests/:id/attestation), copied here independently of src/.
    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    IPoolManager internal manager;
    CabalCoin internal token;
    MockERC20 internal imd;
    CabalHook internal hook;
    CabalGate internal gate;
    MockIntake internal intake;
    PoolKey internal key;

    function setUp() public virtual {
        _setup(true, false);
    }

    function _setup(bool imd0, bool oneSided) internal {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(12345);
        manager = IPoolManager(address(new PoolManager(address(this))));
        address pairAddress = imd0 ? address(0x1000) : address(type(uint160).max - 1);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("IdentityMD", "IMD", 0), pairAddress);
        imd = MockERC20(pairAddress);
        imd.mint(address(this), 100_000_000 ether);
        imd.mint(ALICE, 1_000_000 ether);
        imd.mint(BOB, 1_000_000 ether);
        _launch(imd0, oneSided ? TickMath.getSqrtPriceAtTick(imd0 ? UPPER : LOWER) : Q96);
        modify(LOWER, UPPER, int256(SEED_LIQUIDITY));
        intake = new MockIntake();
        gate = deployGate(hook);
        vm.prank(hook.owner());
        hook.setGate(address(gate));
        vm.startPrank(ALICE);
        imd.approve(address(gate), type(uint256).max);
        token.approve(address(gate), type(uint256).max);
        vm.stopPrank();
        vm.prank(BOB);
        imd.approve(address(gate), type(uint256).max);
    }

    /// @dev Deploys the token and the hook (with this contract as explicit owner) and initializes the pool.
    ///      The launch rehearsal overrides this with a factory that does all three in one call.
    function _launch(bool imd0, uint160 price) internal virtual {
        token = new CabalCoin();
        bytes memory creation = abi.encodePacked(type(CabalHook).creationCode, abi.encode(manager, address(this), imd));
        (bytes32 salt, address predicted) = HookSaltMiner.find(address(this), keccak256(creation), 0, 200000);
        hook = new CabalHook{salt: salt}(manager, address(this), imd);
        assertEq(address(hook), predicted);
        key = PoolKey(
            Currency.wrap(imd0 ? address(imd) : address(token)),
            Currency.wrap(imd0 ? address(token) : address(imd)),
            12500,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, price);
    }

    /// @dev The launch constructor takes the pool as flat words and never reads the hook; here they are copied
    ///      from the local hook so the gate describes the pool the hook bound.
    function deployGate(CabalHook launchHook) internal returns (CabalGate) {
        CabalGate.Config memory cfg = defaultConfig();
        PoolKey memory hookKey = launchHook.poolKey();
        return CabalGate(
            deployCode(
                "CabalGate.sol:CabalGate",
                abi.encode(
                    launchHook,
                    launchHook.poolManager(),
                    launchHook.cabal(),
                    Currency.unwrap(hookKey.currency0),
                    Currency.unwrap(hookKey.currency1),
                    hookKey.fee,
                    uint24(hookKey.tickSpacing),
                    address(this),
                    cfg.intake,
                    cfg.imd,
                    cfg.signer,
                    cfg.action,
                    cfg.maxBuyAmount,
                    cfg.maxSellAmount,
                    cfg.maxImpactBps,
                    cfg.maxDriftBps,
                    cfg.panelSize,
                    cfg.quorum,
                    cfg.windowHours
                )
            )
        );
    }

    /// @dev The flat constructor selects the gate itself as verifier and the canonical boolean type.
    function defaultConfig() internal view returns (CabalGate.Config memory) {
        return CabalGate.Config(
            address(intake),
            address(imd),
            vm.addr(ORACLE_KEY),
            address(0),
            bytes32("oracle.request@oracle-1"),
            10000 ether,
            10000 ether,
            MAX_IMPACT,
            MAX_DRIFT,
            30,
            20,
            1,
            0
        );
    }

    function modify(int24 lower, int24 upper, int256 liquidity) internal returns (BalanceDelta delta) {
        bytes memory result = manager.unlock(abi.encode(uint8(0), lower, upper, liquidity));
        delta = abi.decode(result, (BalanceDelta));
    }

    function directSwap(bool input0) external {
        manager.unlock(abi.encode(uint8(1), input0));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint8 mode = abi.decode(data, (uint8));
        BalanceDelta delta;
        if (mode == 0) {
            (, int24 lower, int24 upper, int256 liquidity) = abi.decode(data, (uint8, int24, int24, int256));
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, 0), "");
        } else {
            (, bool input0) = abi.decode(data, (uint8, bool));
            delta = manager.swap(
                key,
                SwapParams(input0, -1 ether, input0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta > 0) manager.take(currency, address(this), uint128(delta));
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        }
    }

    function submit(bool isBuy, uint256 amount) internal returns (bytes32 id) {
        return submitAs(ALICE, isBuy, amount);
    }

    function submitAs(address who, bool isBuy, uint256 amount) internal returns (bytes32 id) {
        vm.prank(who);
        return isBuy
            ? gate.submitBuyRequest(amount, "Fund my community research for October")
            : gate.submitSellRequest(amount, "Pay October community hosting expenses");
    }

    /// @dev The oracle's own request id is a UUID left-aligned in bytes32 and unrelated to the Intake's id.
    function oracleIdOf(bytes32 id) internal pure returns (bytes32) {
        return bytes32(bytes16(keccak256(abi.encode("oracle request", id))));
    }

    /// @dev Test-side reconstruction of the oracle's questionHash from the body the Intake received: keccak256 of
    ///      the sorted-key JSON of {answerType, chainId, definitions, evidence, question, v, window{fromBlock,toBlock}}.
    function expectedQuestionHash(bytes32 id, uint64 fromBlock, uint64 toBlock) internal view returns (bytes32) {
        string memory body = string(intake.bodyOf(id));
        return keccak256(
            abi.encodePacked(
                '{"answerType":"bool","chainId":1,"definitions":{"amount":"',
                jsonEscape(vm.parseJsonString(body, ".definitions.amount")),
                '","costBasis":"',
                jsonEscape(vm.parseJsonString(body, ".definitions.costBasis")),
                '","impact":"',
                jsonEscape(vm.parseJsonString(body, ".definitions.impact")),
                '","reason":"',
                jsonEscape(vm.parseJsonString(body, ".definitions.reason")),
                '"},"evidence":"panel","question":"',
                jsonEscape(vm.parseJsonString(body, ".question")),
                '","v":1,"window":{"fromBlock":',
                vm.toString(uint256(fromBlock)),
                ',"toBlock":',
                vm.toString(uint256(toBlock)),
                "}}"
            )
        );
    }

    function jsonEscape(string memory s) internal pure returns (string memory) {
        bytes memory input = bytes(s);
        bytes memory out = new bytes(input.length * 2);
        uint256 k;
        for (uint256 i; i < input.length; ++i) {
            if (input[i] == '"' || input[i] == "\\") out[k++] = "\\";
            out[k++] = input[i];
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
        return string(out);
    }

    function attestation(bytes32 id, bool yes) internal view returns (Attestation memory a) {
        uint64 fromBlock = uint64(block.number - 300);
        uint64 toBlock = uint64(block.number - 1);
        a = Attestation({
            requestId: oracleIdOf(id),
            chainId: 1,
            questionHash: expectedQuestionHash(id, fromBlock, toBlock),
            answerType: 0,
            answer: abi.encode(yes),
            figure: 0,
            fromBlock: fromBlock,
            toBlock: toBlock,
            blockHash: keccak256("block"),
            panelJobId: keccak256("panel job"),
            panelSize: 30,
            quorum: 20,
            agreed: 22,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 900)
        });
    }

    // Independent test-side EIP-712 implementation: never call the production digest to sign fixtures.
    function sign(Attestation memory a, uint256 privateKey, address verifier) internal pure returns (bytes memory) {
        return signFor(a, privateKey, 1, verifier);
    }

    function signFor(Attestation memory a, uint256 privateKey, uint256 chainId, address verifier)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                chainId,
                verifier
            )
        );
        bytes32 data = keccak256(
            abi.encode(
                TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, keccak256(abi.encodePacked("\x19\x01", domain, data)));
        return abi.encodePacked(r, s, v);
    }

    function deliverTrue(bytes32 id) internal {
        Attestation memory a = attestation(id, true);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(gate)));
    }

    function approve(bytes32 id) internal {
        approveFor(id, ALICE);
    }

    function approveFor(bytes32 id, address who) internal {
        deliverTrue(id);
        vm.prank(who);
        gate.setSlippageLimit(id, 1);
    }

    function buy(uint256 amount) internal returns (uint256 out) {
        bytes32 id = submit(true, amount);
        approve(id);
        vm.prank(ALICE);
        return gate.executeBuyRequest(id);
    }

    function assertSettled() internal view {
        assertEq(manager.currencyDelta(address(gate), key.currency0), 0);
        assertEq(manager.currencyDelta(address(gate), key.currency1), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertFalse(hook.awaitingFee());
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(token.balanceOf(address(gate)), 0);
        assertEq(imd.allowance(address(gate), address(hook)), 0);
        assertEq(imd.allowance(address(gate), address(intake)), 0);
    }

    function contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return countOf(haystack, needle) > 0;
    }

    function countOf(string memory haystack, string memory needle) internal pure returns (uint256 count) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return 0;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool found = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) ++count;
        }
    }
}
