// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {PriceMath} from "./libraries/PriceMath.sol";

/// @notice Stateless indicative price-impact estimate for one pool, deployed by the gate beside QuestionBuilder.
/// @dev Uses the liquidity active at the current price or, when none is active, the nearest initialised
///      liquidity in the swap direction, counting the empty gap as movement: that is the path a v4 swap takes.
///      Single range; further tick crossings are not modelled, and the panel must assess depth independently.
contract ImpactEstimator {
    using StateLibrary for IPoolManager;

    uint256 private constant Q96 = 1 << 96;
    /// @dev Tick-bitmap words scanned per direction when no liquidity is active at the current price.
    uint256 private constant MAX_BITMAP_WORDS = 32;
    IPoolManager public immutable poolManager;
    PoolKey private _key;

    constructor(IPoolManager manager, PoolKey memory key) {
        poolManager = manager;
        _key = key;
    }

    /// @notice Movement in bps between the current price and the price after an exact-input swap of `amount`,
    ///         or 10000 when no liquidity can be reached in that direction.
    function estimate(bool input0, uint256 amount) external view returns (uint256) {
        PoolId poolId = _key.toId();
        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint160 start = sqrtPrice;
        if (liquidity == 0) {
            (bool found, int24 next) = _nextInitializedTick(poolId, tick, input0);
            if (!found) return 10000;
            (, int128 liquidityNet) = poolManager.getTickLiquidity(poolId, next);
            // Crossing downward removes liquidityNet; crossing upward adds it.
            int256 entered = input0 ? -int256(liquidityNet) : int256(liquidityNet);
            if (entered <= 0) return 10000;
            liquidity = uint128(uint256(entered));
            start = TickMath.getSqrtPriceAtTick(next);
        }
        uint256 net = FullMath.mulDiv(amount, 1_000_000 - _key.fee, 1_000_000);
        uint256 end;
        if (input0) {
            // sqrtP' = L * sqrtP / (L + net * sqrtP / Q96)
            end = FullMath.mulDiv(liquidity, start, uint256(liquidity) + FullMath.mulDiv(net, start, Q96));
            if (end < TickMath.MIN_SQRT_PRICE) return 10000;
        } else {
            // sqrtP' = sqrtP + net * Q96 / L
            end = uint256(start) + FullMath.mulDiv(net, Q96, liquidity);
            if (end > TickMath.MAX_SQRT_PRICE) return 10000;
        }
        return PriceMath.movement(sqrtPrice, uint160(end));
    }

    /// @dev Next initialised tick at or below `tick` (lte) or strictly above it, scanning the pool's tick bitmap.
    function _nextInitializedTick(PoolId poolId, int24 tick, bool lte) private view returns (bool, int24) {
        int24 spacing = _key.tickSpacing;
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        if (!lte) compressed++;
        int24 minCompressed = TickMath.minUsableTick(spacing) / spacing;
        int24 maxCompressed = TickMath.maxUsableTick(spacing) / spacing;
        for (uint256 i; i < MAX_BITMAP_WORDS; ++i) {
            if (compressed < minCompressed || compressed > maxCompressed) return (false, 0);
            int16 wordPos = int16(compressed >> 8);
            uint8 bitPos = uint8(uint256(int256(compressed)) & 0xff);
            uint256 word = poolManager.getTickBitmap(poolId, wordPos);
            if (lte) {
                uint256 masked = word & (type(uint256).max >> (255 - bitPos));
                if (masked != 0) {
                    return (true, (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing);
                }
                compressed = compressed - int24(uint24(bitPos)) - 1;
            } else {
                uint256 masked = word & ~((uint256(1) << bitPos) - 1);
                if (masked != 0) {
                    return (true, (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing);
                }
                compressed = compressed + int24(uint24(255 - bitPos)) + 1;
            }
        }
        return (false, 0);
    }
}
