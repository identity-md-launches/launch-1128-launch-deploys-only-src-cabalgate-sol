// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

interface IGateBinding {
    function hook() external view returns (CabalHook);
    function cabal() external view returns (IERC20);
}

/// @notice One CABAL/IMD pool, one immutable gate binding, and permanently owned protocol positions.
/// @dev Fee completion runs inside the gate's unlock after input settlement and output collection.
///      No hook-return-delta permissions are needed; the gate cannot return without paying the hook.
contract CabalHook is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error Unauthorized();
    error InvalidPool();
    error InvalidGate();
    error InvalidSwap();
    error FeeNotCompleted();
    error UnsupportedToken();
    error InvalidRange();

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant Q96 = 1 << 96;
    IPoolManager public immutable poolManager;
    /// @notice The account that originated the transaction deploying this hook: the launch's initial owner
    ///         whenever the constructor was not given an explicit one.
    address public immutable launcher;
    /// @notice Whoever initialized the bound pool (the launch factory), recorded for reference only.
    address public initializer;
    IERC20 public imd;
    address public cabal;
    address public gate;
    bool public initialized;
    bool public awaitingFee;
    uint256 public feeBase;
    uint256 public totalBurned;
    uint256 public totalPolAllocated;
    PoolKey private _key;
    bool private _compounding;

    event PoolBound(bytes32 indexed poolId, address indexed cabal);
    event GateBound(address indexed gate);
    event ImdConfigured(address indexed imd);
    event FeePaid(uint256 imdVolume, uint256 burned, uint256 pol);
    event ProtocolLiquidityAdded(int24 lower, int24 upper, uint128 liquidity, address currency, uint256 budget);

    /// @param initialOwner The hook owner, who binds the gate once. The launch manifest can only resolve the
    ///        PoolManager and the token, so `address(0)` or `0xdead` means "unspecified": ownership then goes to the
    ///        externally owned account that originated the launch transaction (`tx.origin`, read once here and
    ///        never used to authorize a later call), which must hand it over with the two-step transfer.
    ///        Binding stays owner-only because a permissionless first-come binding could be back-run in the
    ///        launch block by a hostile gate, and the binding is permanent.
    constructor(IPoolManager manager, address initialOwner, IERC20 pair) Ownable(_launchOwner(initialOwner)) {
        if (address(manager) == address(0) || address(pair) == address(0)) revert InvalidPool();
        poolManager = manager;
        launcher = tx.origin;
        imd = pair;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function _launchOwner(address initialOwner) private view returns (address) {
        return initialOwner == address(0) || initialOwner == DEAD ? tx.origin : initialOwner;
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }
    modifier onlyGate() {
        if (msg.sender != gate || gate == address(0)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    /// @notice Owner-configurable before pool binding. v4 pool currencies cannot be changed afterward.
    function setIMD(IERC20 pair) external onlyOwner {
        if (initialized || address(pair) == address(0)) revert InvalidPool();
        imd = pair;
        emit ImdConfigured(address(pair));
    }

    function setGate(address candidate) external onlyOwner {
        if (
            !initialized || gate != address(0) || candidate.code.length == 0
                || address(IGateBinding(candidate).hook()) != address(this)
                || address(IGateBinding(candidate).cabal()) != cabal
        ) revert InvalidGate();
        gate = candidate;
        emit GateBound(candidate);
    }

    /// @dev Binds the first pool with the launch parameters, whoever initializes it. The factory deploys this hook
    ///      and initializes in the same transaction, so nobody else can reach the hook first; an explicit factory
    ///      address could not be expressed by the launch manifest. Any later pool is refused.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            initialized || address(key.hooks) != address(this) || key.fee != 12_500 || key.tickSpacing != 60
                || c0 == address(0) || c0 >= c1 || (c0 != address(imd) && c1 != address(imd))
        ) revert InvalidPool();
        cabal = c0 == address(imd) ? c1 : c0;
        _key = key;
        initializer = sender;
        initialized = true;
        emit PoolBound(PoolId.unwrap(key.toId()), cabal);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkSwap(sender, key, params);
        if (awaitingFee) revert FeeNotCompleted();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        _checkSwap(sender, key, params);
        if (awaitingFee) revert FeeNotCompleted();
        int256 amount =
            Currency.unwrap(key.currency0) == address(imd) ? int256(delta.amount0()) : int256(delta.amount1());
        feeBase = uint256(amount < 0 ? -amount : amount);
        awaitingFee = true;
        return (IHooks.afterSwap.selector, 0);
    }

    function _checkSwap(address sender, PoolKey calldata key, SwapParams calldata params) private view {
        if (sender != gate || gate == address(0)) revert Unauthorized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_key.toId())) revert InvalidPool();
        if (params.amountSpecified >= 0) revert InvalidSwap();
    }

    /// @notice Each 25 bps leg rounds down independently in IMD minor units.
    function feeFor(uint256 volume) public pure returns (uint256) {
        return (volume / 400) * 2;
    }

    function finishSwap() external onlyGate nonReentrant returns (uint256 fee) {
        if (!awaitingFee) revert InvalidSwap();
        uint256 volume = feeBase;
        uint256 half = volume / 400;
        fee = half * 2;
        awaitingFee = false;
        feeBase = 0;
        if (fee != 0) {
            uint256 beforeBalance = imd.balanceOf(address(this));
            imd.safeTransferFrom(msg.sender, address(this), fee);
            if (imd.balanceOf(address(this)) != beforeBalance + fee) revert UnsupportedToken();
            imd.safeTransfer(DEAD, half);
            totalBurned += half;
            totalPolAllocated += half;
            _addSingleSided(Currency.unwrap(_key.currency0) == address(imd), imd.balanceOf(address(this)));
        }
        emit FeePaid(volume, half, half);
    }

    /// @notice Permissionless fee collection and reinvestment; no principal withdrawal is exposed.
    function compound(int24 lower, int24 upper) external nonReentrant {
        if (!initialized || awaitingFee) revert InvalidSwap();
        _compounding = true;
        poolManager.unlock(abi.encode(lower, upper));
        _compounding = false;
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (!_compounding) revert Unauthorized();
        (int24 lower, int24 upper) = abi.decode(data, (int24, int24));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(_key, ModifyLiquidityParams(lower, upper, 0, 0), "");
        _settle(delta);
        _addSingleSided(true, IERC20(Currency.unwrap(_key.currency0)).balanceOf(address(this)));
        _addSingleSided(false, IERC20(Currency.unwrap(_key.currency1)).balanceOf(address(this)));
        return "";
    }

    /// @dev Single-sided positions start just outside the current tick and span ten tick intervals.
    /// Rounding residue stays in the hook and is included in the next deposit. No donation substitutes for POL.
    function _addSingleSided(bool token0, uint256 amount) private {
        if (amount == 0) return;
        (, int24 tick,,) = poolManager.getSlot0(_key.toId());
        int24 grid = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) grid -= 60;
        int24 lower = token0 ? grid + 60 : grid - 600;
        int24 upper = token0 ? grid + 660 : grid;
        if (lower < TickMath.minUsableTick(60) || upper > TickMath.maxUsableTick(60)) revert InvalidRange();
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 liquidity = token0
            ? FullMath.mulDiv(amount, FullMath.mulDiv(a, b, Q96), uint256(b) - a)
            : FullMath.mulDiv(amount, Q96, uint256(b) - a);
        if (liquidity == 0) return;
        // Bound to int128 as required by v4, without truncating to a smaller type.
        if (liquidity > uint256(uint128(type(int128).max))) revert InvalidRange();
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(_key, ModifyLiquidityParams(lower, upper, int256(liquidity), 0), "");
        _settle(delta);
        emit ProtocolLiquidityAdded(
            lower, upper, uint128(liquidity), Currency.unwrap(token0 ? _key.currency0 : _key.currency1), amount
        );
    }

    function _settle(BalanceDelta delta) private {
        _settleCurrency(_key.currency0, delta.amount0());
        _settleCurrency(_key.currency1, delta.amount1());
    }

    function _settleCurrency(Currency currency, int128 delta) private {
        if (delta > 0) {
            poolManager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), owed);
            if (poolManager.settle() != owed) revert UnsupportedToken();
        }
    }
}
