// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {CabalCoin} from "../src/CabalCoin.sol";

contract CabalCoinTest is Test {
    CabalCoin token;

    function setUp() public {
        token = new CabalCoin();
    }

    function test_launchSupplyMetadataAndPlainTransfer() public {
        assertEq(token.name(), "CabalCoin");
        assertEq(token.symbol(), "CABAL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        token.transfer(address(123), 100 ether);
        assertEq(token.balanceOf(address(123)), 100 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_allowanceAndInsufficientBalances() public {
        token.approve(address(123), 100 ether);
        vm.prank(address(123));
        token.transferFrom(address(this), address(456), 99 ether);
        assertEq(token.allowance(address(this), address(123)), 1 ether);
        vm.prank(address(123));
        vm.expectRevert();
        token.transferFrom(address(this), address(456), 2 ether);
        vm.prank(address(789));
        vm.expectRevert();
        token.transfer(address(456), 1);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    function test_noAdministrativeMint() public {
        (bool success,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 100));
        assertFalse(success);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(address(123), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(123)), token.totalSupply());
    }

    function test_runtimeNoEscapeHatches() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
