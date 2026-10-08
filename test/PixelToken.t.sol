// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelToken} from "../src/PixelToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract PixelTokenTest is Test {
    PixelToken internal token;

    function setUp() public {
        token = new PixelToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Pixel Pool");
        assertEq(token.symbol(), "PIXEL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transfersConserveSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromConsumesAllowance() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, 42 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 40 ether);
        assertEq(token.allowance(address(this), spender), 2 ether);
        assertEq(token.balanceOf(recipient), 40 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2 ether, 3 ether)
        );
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 3 ether);
    }

    function test_invalidTransfersFail() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 1e27, 1e27 + 1)
        );
        token.transfer(makeAddr("recipient"), 1e27 + 1);
    }

    function test_noMintOrAdministrationEvenForDeployer() public {
        bytes[7] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", address(this), 1),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("initialize(address)", address(this)),
            abi.encodeWithSignature("setFee(uint256)", 1),
            abi.encodeWithSignature("burn(uint256)", 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
        }
    }
}
