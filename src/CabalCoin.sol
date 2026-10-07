// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain, immutable launch token. Admission and swap fees live outside the token.
contract CabalCoin is ERC20 {
    constructor() ERC20("CabalCoin", "CABAL") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
