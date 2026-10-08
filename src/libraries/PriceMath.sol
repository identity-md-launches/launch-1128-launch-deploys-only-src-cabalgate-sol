// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

library PriceMath {
    uint256 internal constant Q96 = 1 << 96;

    /// @notice Symmetric relative price movement in bps: 1 - min(priceA,priceB)/max(priceA,priceB).
    function movement(uint160 a, uint160 b) internal pure returns (uint256) {
        uint256 ratio = a < b ? FullMath.mulDiv(a, Q96, b) : FullMath.mulDiv(b, Q96, a);
        return 10000 - FullMath.mulDiv(FullMath.mulDiv(ratio, ratio, Q96), 10000, Q96);
    }
}
