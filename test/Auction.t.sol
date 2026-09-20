// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bid} from "../src/Bid.sol";
import {SealedBidAuction} from "../src/SealedBidAuction.sol";

contract AuctionTest is Test {
    Bid token;
    SealedBidAuction auction;
    address seller = address(1);
    address alice = address(2);
    address bob = address(3);
    bytes32 constant SALT = keccak256("secret");
    uint256 end;
    uint256 id;

    function setUp() public {
        token = new Bid();
        auction = new SealedBidAuction(address(token));
        end = block.timestamp + 100;
        vm.prank(seller);
        id = auction.list(bytes32("item"), 10, end);
        token.transfer(alice, 1000);
        token.transfer(bob, 1000);
        vm.prank(alice);
        token.approve(address(auction), type(uint256).max);
        vm.prank(bob);
        token.approve(address(auction), type(uint256).max);
    }

    function commit(address who, uint256 amount, uint256 locked) internal {
        bytes32 hash = keccak256(abi.encode(block.chainid, address(auction), id, who, amount, SALT));
        vm.prank(who);
        auction.commit(id, hash, locked);
    }

    function reveal(address who, uint256 amount) internal {
        vm.prank(who);
        auction.reveal(id, amount, SALT);
    }

    function settle() internal {
        vm.warp(end + 1 days);
        auction.finalize(id);
    }

    function testWinnerLoserAndExcessConservation() public {
        commit(alice, 100, 150);
        commit(bob, 80, 200);
        vm.warp(end);
        reveal(bob, 80);
        reveal(alice, 100);
        settle();
        assertEq(auction.proceeds(seller), 100);
        vm.prank(bob);
        auction.withdraw(id);
        vm.prank(alice);
        auction.withdraw(id);
        vm.prank(seller);
        auction.withdrawProceeds();
        assertEq(token.balanceOf(alice), 900);
        assertEq(token.balanceOf(bob), 1000);
        assertEq(token.balanceOf(seller), 100);
        assertEq(token.balanceOf(address(auction)), 0);
        vm.expectRevert("nothing to withdraw");
        vm.prank(alice);
        auction.withdraw(id);
        vm.expectRevert("nothing to withdraw");
        vm.prank(seller);
        auction.withdrawProceeds();
        vm.expectRevert("already finalized");
        auction.finalize(id);
    }

    function testTieUsesCommitOrderNotRevealOrder() public {
        commit(alice, 80, 80);
        commit(bob, 80, 80);
        vm.warp(end);
        reveal(bob, 80);
        reveal(alice, 80);
        settle();
        (, uint256 a,,) = auction.bids(id, alice);
        (, uint256 b,,) = auction.bids(id, bob);
        assertEq(a, 0);
        assertEq(b, 80);
    }

    function testNoRevealAndInvalidRevealRefund() public {
        commit(alice, 9, 50);
        commit(bob, 60, 50);
        vm.warp(end);
        vm.expectRevert("invalid bid");
        reveal(alice, 9);
        vm.expectRevert("invalid bid");
        reveal(bob, 60);
        settle();
        assertEq(auction.proceeds(seller), 0);
        vm.prank(alice);
        auction.withdraw(id);
        vm.prank(bob);
        auction.withdraw(id);
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testEmptyAuctionAndZeroBid() public {
        vm.prank(seller);
        uint256 empty = auction.list(bytes32("empty"), 0, end);
        vm.prank(seller);
        id = auction.list(bytes32("zero"), 0, end);
        commit(alice, 0, 1);
        vm.warp(end);
        vm.expectRevert("invalid bid");
        reveal(alice, 0);
        settle();
        auction.finalize(empty);
        assertEq(auction.proceeds(seller), 0);
        vm.prank(alice);
        auction.withdraw(id);
        assertEq(token.balanceOf(alice), 1000);
    }

    function testPhaseAndDuplicateFailures() public {
        commit(alice, 20, 50);
        vm.expectRevert("already committed");
        commit(alice, 20, 50);
        vm.expectRevert("reveal phase");
        reveal(alice, 20);
        vm.expectRevert("not finalized");
        vm.prank(alice);
        auction.withdraw(id);
        vm.expectRevert("settlement phase");
        auction.finalize(id);
        vm.warp(end);
        vm.expectRevert("commit phase");
        commit(bob, 20, 50);
        vm.expectRevert("hash mismatch");
        reveal(alice, 21);
        reveal(alice, 20);
        vm.expectRevert("not revealable");
        reveal(alice, 20);
        vm.warp(end + 1 days);
        vm.expectRevert("reveal phase");
        reveal(alice, 20);
        auction.finalize(id);
    }

    function testInvalidTokenConstructor() public {
        vm.expectRevert("invalid token");
        new SealedBidAuction(address(0));
    }

    function testPermissionsAndInvalidInputs() public {
        vm.expectRevert("deadline");
        auction.list(bytes32(0), 0, block.timestamp);
        vm.expectRevert("seller bid");
        vm.prank(seller);
        auction.commit(id, SALT, 1);
        vm.expectRevert("empty commitment");
        vm.prank(alice);
        auction.commit(id, bytes32(0), 1);
        vm.expectRevert("empty commitment");
        vm.prank(alice);
        auction.commit(id, SALT, 0);
        vm.expectRevert("commit phase");
        auction.commit(999, SALT, 10);
        vm.expectRevert("settlement phase");
        auction.finalize(999);
        vm.prank(alice);
        token.approve(address(auction), 0);
        vm.expectRevert("allowance");
        commit(alice, 20, 50);
        (bytes32 digest,,,) = auction.bids(id, alice);
        assertEq(digest, bytes32(0));
        vm.prank(alice);
        token.approve(address(auction), 2000);
        vm.expectRevert("balance");
        commit(alice, 20, 2000);
        assertEq(token.allowance(alice, address(auction)), 2000);
    }

    function testHashDomainSeparation() public {
        bytes32 h = auction.commitmentHash(id, alice, 20, SALT);
        assertTrue(h != auction.commitmentHash(id, bob, 20, SALT));
        assertTrue(h != auction.commitmentHash(id + 1, alice, 20, SALT));
        SealedBidAuction other = new SealedBidAuction(address(token));
        assertTrue(h != other.commitmentHash(id, alice, 20, SALT));
        vm.chainId(block.chainid + 1);
        assertTrue(h != auction.commitmentHash(id, alice, 20, SALT));
    }

    function testFuzzConservation(uint96 x, uint96 y) public {
        uint256 a = bound(x, 10, 1000);
        uint256 b = bound(y, 10, 1000);
        commit(alice, a, 1000);
        commit(bob, b, 1000);
        vm.warp(end);
        reveal(bob, b);
        reveal(alice, a);
        settle();
        uint256 price = a >= b ? a : b;
        assertEq(auction.proceeds(seller), price);
        (, uint256 ar,,) = auction.bids(id, alice);
        (, uint256 br,,) = auction.bids(id, bob);
        assertEq(ar + br + price, token.balanceOf(address(auction)));
        if (ar > 0) {
            vm.prank(alice);
            auction.withdraw(id);
        }
        if (br > 0) {
            vm.prank(bob);
            auction.withdraw(id);
        }
        vm.prank(seller);
        auction.withdrawProceeds();
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testMultipleAuctionsRemainIsolated() public {
        commit(alice, 20, 50);
        vm.prank(seller);
        uint256 second = auction.list(bytes32("other"), 0, end);
        bytes32 hash = auction.commitmentHash(second, bob, 30, SALT);
        vm.prank(bob);
        auction.commit(second, hash, 80);
        vm.warp(end);
        reveal(alice, 20);
        vm.prank(bob);
        auction.reveal(second, 30, SALT);
        settle();
        assertEq(auction.proceeds(seller), 20);
        auction.finalize(second);
        assertEq(auction.proceeds(seller), 50);
        vm.prank(alice);
        auction.withdraw(id);
        vm.prank(bob);
        auction.withdraw(second);
        vm.prank(seller);
        auction.withdrawProceeds();
        assertEq(token.balanceOf(address(auction)), 0);
    }
}

/// @dev Exact-transfer mock that can refuse transfers or attempt arbitrary callbacks.
contract HostileToken {
    mapping(address => uint256) public balanceOf;
    bool public fail;
    bool public revertTransfer;
    address public target;
    bytes public callback;
    bool public attempted;
    bool public succeeded;
    bytes public callbackResult;

    function configure(address t, bytes calldata data, bool f, bool r) external {
        target = t;
        callback = data;
        fail = f;
        revertTransfer = r;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return move(from, to, amount);
    }

    function move(address from, address to, uint256 amount) internal returns (bool) {
        require(!revertTransfer, "denied");
        if (fail) return false;
        if (target != address(0)) {
            attempted = true;
            (succeeded, callbackResult) = target.call(callback);
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract HostileTokenTest is Test {
    HostileToken token;
    SealedBidAuction auction;
    uint256 id;
    uint256 end;

    function setUp() public {
        token = new HostileToken();
        auction = new SealedBidAuction(address(token));
        end = block.timestamp + 100;
        vm.prank(address(1));
        id = auction.list(bytes32(0), 1, end);
        token.mint(address(this), 100);
    }

    function testFalseAndRevertingTransfersRollbackAndRetry() public {
        bytes32 h = auction.commitmentHash(id, address(this), 20, bytes32(0));
        token.configure(address(0), "", true, false);
        vm.expectRevert("token transferFrom failed");
        auction.commit(id, h, 100);
        (bytes32 digest,,,) = auction.bids(id, address(this));
        assertEq(digest, bytes32(0));
        token.configure(address(0), "", false, true);
        vm.expectRevert("denied");
        auction.commit(id, h, 100);
        token.configure(address(0), "", false, false);
        auction.commit(id, h, 100);
        vm.warp(end);
        auction.reveal(id, 20, bytes32(0));
        vm.warp(end + 1 days);
        auction.finalize(id);
        token.configure(address(0), "", true, false);
        vm.expectRevert("token transfer failed");
        auction.withdraw(id);
        (, uint256 locked,,) = auction.bids(id, address(this));
        assertEq(locked, 80);
        vm.expectRevert("token transfer failed");
        vm.prank(address(1));
        auction.withdrawProceeds();
        assertEq(auction.proceeds(address(1)), 20);
        token.configure(address(0), "", false, true);
        vm.expectRevert("denied");
        auction.withdraw(id);
        token.configure(address(0), "", false, false);
        auction.withdraw(id);
        vm.prank(address(1));
        auction.withdrawProceeds();
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testReentrantTokenCannotEnterAnyMutation() public {
        bytes32 h = auction.commitmentHash(id, address(this), 20, bytes32(0));
        token.configure(address(auction), abi.encodeCall(auction.list, (bytes32(0), 0, end)), false, false);
        auction.commit(id, h, 100);
        assertTrue(token.attempted());
        assertFalse(token.succeeded());
        assertEq(token.callbackResult(), abi.encodeWithSignature("Error(string)", "reentrancy"));
        assertEq(auction.auctionCount(), 1);
        vm.warp(end);
        auction.reveal(id, 20, bytes32(0));
        vm.warp(end + 1 days);
        auction.finalize(id);
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(auction.commit, (id, h, 1));
        calls[1] = abi.encodeCall(auction.reveal, (id, 20, bytes32(0)));
        calls[2] = abi.encodeCall(auction.finalize, (id));
        calls[3] = abi.encodeCall(auction.withdraw, (id));
        calls[4] = abi.encodeCall(auction.withdrawProceeds, ());
        calls[5] = abi.encodeCall(auction.list, (bytes32(0), 0, block.timestamp + 100));
        for (uint256 i; i < calls.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            token.configure(address(auction), calls[i], false, false);
            auction.withdraw(id);
            assertFalse(token.succeeded());
            assertEq(token.callbackResult(), abi.encodeWithSignature("Error(string)", "reentrancy"));
            assertTrue(vm.revertToState(snapshot));
        }
        token.configure(address(auction), abi.encodeCall(auction.withdrawProceeds, ()), false, false);
        vm.prank(address(1));
        auction.withdrawProceeds();
        assertFalse(token.succeeded());
        assertEq(token.callbackResult(), abi.encodeWithSignature("Error(string)", "reentrancy"));
        assertEq(auction.proceeds(address(1)), 0);
    }
}
