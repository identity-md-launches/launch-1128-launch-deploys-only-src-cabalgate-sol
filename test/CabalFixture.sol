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
    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreementBps,uint64 issuedAt,uint64 expiresAt)"
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
        token = new CabalCoin();
        address pairAddress = imd0 ? address(0x1000) : address(type(uint160).max - 1);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("IdentityMD", "IMD", 0), pairAddress);
        imd = MockERC20(pairAddress);
        imd.mint(address(this), 100_000_000 ether);
        imd.mint(ALICE, 1_000_000 ether);
        imd.mint(BOB, 1_000_000 ether);
        bytes memory creation =
            abi.encodePacked(type(CabalHook).creationCode, abi.encode(manager, address(this), imd, address(this)));
        (bytes32 salt, address predicted) = HookSaltMiner.find(address(this), keccak256(creation), 0, 200000);
        hook = new CabalHook{salt: salt}(manager, address(this), imd, address(this));
        assertEq(address(hook), predicted);
        key = PoolKey(
            Currency.wrap(imd0 ? address(imd) : address(token)),
            Currency.wrap(imd0 ? address(token) : address(imd)),
            12500,
            60,
            IHooks(address(hook))
        );
        uint160 price = oneSided ? TickMath.getSqrtPriceAtTick(imd0 ? UPPER : LOWER) : Q96;
        manager.initialize(key, price);
        modify(LOWER, UPPER, int256(SEED_LIQUIDITY));
        intake = new MockIntake();
        CabalGate.Config memory cfg = CabalGate.Config(
            address(intake),
            address(imd),
            vm.addr(ORACLE_KEY),
            address(intake),
            bytes32("oracle.request@oracle-1"),
            10000 ether,
            10000 ether,
            500,
            1,
            0
        );
        gate = new CabalGate(hook, address(this), cfg);
        hook.setGate(address(gate));
        vm.startPrank(ALICE);
        imd.approve(address(gate), type(uint256).max);
        token.approve(address(gate), type(uint256).max);
        vm.stopPrank();
        vm.prank(BOB);
        imd.approve(address(gate), type(uint256).max);
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
        vm.prank(ALICE);
        return isBuy
            ? gate.submitBuyRequest(amount, "Fund my community research for October")
            : gate.submitSellRequest(amount, "Pay October community hosting expenses");
    }

    function attestation(bytes32 id, bool yes) internal view returns (Attestation memory a) {
        CabalGate.Request memory r = gate.getRequest(id);
        a = Attestation(
            id,
            1,
            r.questionHash,
            0,
            abi.encode(yes),
            uint64(block.number - 1),
            uint64(block.number),
            keccak256("block"),
            keccak256("panel job"),
            30,
            20,
            8000,
            uint64(block.timestamp),
            uint64(block.timestamp + 900)
        );
    }

    // Independent test-side EIP-712 implementation: never call the production digest to sign fixtures.
    function sign(Attestation memory a, uint256 privateKey, address verifier) internal pure returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                uint256(1),
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
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.panelSize,
                a.quorum,
                a.agreementBps,
                a.issuedAt,
                a.expiresAt
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, keccak256(abi.encodePacked("\x19\x01", domain, data)));
        return abi.encodePacked(r, s, v);
    }

    function approve(bytes32 id) internal {
        Attestation memory a = attestation(id, true);
        intake.deliver(gate, id, a, sign(a, ORACLE_KEY, address(intake)));
        vm.prank(ALICE);
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
}
