// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Bid} from "../src/Bid.sol";

contract BidTest is Test {
    Bid token;

    function setUp() public {
        token = new Bid();
    }

    function testMetadataAndSupply() public view {
        assertEq(token.name(), "Bid");
        assertEq(token.symbol(), "BID");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testTransferAndAllowances() public {
        token.approve(address(1), 100);
        vm.prank(address(1));
        token.transferFrom(address(this), address(2), 60);
        assertEq(token.allowance(address(this), address(1)), 40);
        assertEq(token.balanceOf(address(2)), 60);
        vm.expectRevert("allowance");
        vm.prank(address(1));
        token.transferFrom(address(this), address(2), 41);
        token.approve(address(1), type(uint256).max);
        vm.prank(address(1));
        token.transferFrom(address(this), address(2), 1);
        assertEq(token.allowance(address(this), address(1)), type(uint256).max);
        uint256 before = token.balanceOf(address(this));
        token.transfer(address(this), 10);
        assertEq(token.balanceOf(address(this)), before);
        vm.expectRevert("zero recipient");
        token.transfer(address(0), 1);
        vm.expectRevert("balance");
        vm.prank(address(2));
        token.transfer(address(3), 62);
        token.transfer(address(3), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function testNoMintOrAdmin() public {
        bytes4[4] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(1), 100));
            assertFalse(ok);
            vm.prank(address(1));
            (ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(1), 100));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
