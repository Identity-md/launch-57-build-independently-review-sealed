// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IBid {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice BID escrow for off-chain items; delivery is outside this contract.
contract SealedBidAuction {
    IBid public immutable token;
    uint256 public constant REVEAL_PERIOD = 1 days;
    uint256 public auctionCount;
    bool private entered;

    struct Auction {
        address seller;
        bytes32 itemId;
        uint256 reserve;
        uint256 deadline;
        uint256 revealDeadline;
        address winner;
        uint256 highestBid;
        uint256 winningOrder;
        uint256 commitments;
        bool finalized;
    }

    struct Commitment {
        bytes32 digest;
        uint256 locked;
        uint256 order;
        bool revealed;
    }

    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => Commitment)) public bids;
    mapping(address => uint256) public proceeds;

    event Listed(
        uint256 indexed auctionId,
        address indexed seller,
        bytes32 indexed itemId,
        uint256 reserve,
        uint256 deadline,
        uint256 revealDeadline
    );
    event Committed(uint256 indexed auctionId, address indexed bidder, bytes32 digest, uint256 locked, uint256 order);
    event Revealed(uint256 indexed auctionId, address indexed bidder, uint256 amount, bool leading);
    event Finalized(uint256 indexed auctionId, address indexed winner, uint256 price);
    event ProceedsCredited(address indexed seller, uint256 indexed auctionId, uint256 amount);
    event Withdrawn(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event ProceedsWithdrawn(address indexed seller, uint256 amount);

    modifier nonReentrant() {
        require(!entered, "reentrancy");
        entered = true;
        _;
        entered = false;
    }

    constructor(address token_) {
        require(token_.code.length != 0, "invalid token");
        token = IBid(token_);
    }

    function list(bytes32 itemId, uint256 reserve, uint256 deadline) external nonReentrant returns (uint256 id) {
        require(deadline > block.timestamp, "deadline");
        id = ++auctionCount;
        Auction storage a = auctions[id];
        a.seller = msg.sender;
        a.itemId = itemId;
        a.reserve = reserve;
        a.deadline = deadline;
        a.revealDeadline = deadline + REVEAL_PERIOD;
        emit Listed(id, msg.sender, itemId, reserve, deadline, a.revealDeadline);
    }

    function commitmentHash(uint256 id, address bidder, uint256 amount, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), id, bidder, amount, salt));
    }

    function commit(uint256 id, bytes32 digest, uint256 lockAmount) external nonReentrant {
        Auction storage a = auctions[id];
        require(a.seller != address(0) && block.timestamp < a.deadline, "commit phase");
        require(msg.sender != a.seller, "seller bid");
        Commitment storage b = bids[id][msg.sender];
        require(b.digest == bytes32(0), "already committed");
        require(digest != bytes32(0) && lockAmount > 0, "empty commitment");
        b.digest = digest;
        b.locked = lockAmount;
        b.order = ++a.commitments;
        emit Committed(id, msg.sender, digest, lockAmount, b.order);
        require(token.transferFrom(msg.sender, address(this), lockAmount), "token transferFrom failed");
    }

    function reveal(uint256 id, uint256 amount, bytes32 salt) external nonReentrant {
        Auction storage a = auctions[id];
        require(
            a.seller != address(0) && block.timestamp >= a.deadline && block.timestamp < a.revealDeadline,
            "reveal phase"
        );
        Commitment storage b = bids[id][msg.sender];
        require(b.digest != bytes32(0) && !b.revealed, "not revealable");
        require(b.digest == commitmentHash(id, msg.sender, amount, salt), "hash mismatch");
        require(amount > 0 && amount <= b.locked && amount >= a.reserve, "invalid bid");
        b.revealed = true;
        bool leading = amount > a.highestBid || (amount == a.highestBid && b.order < a.winningOrder);
        if (leading) {
            a.winner = msg.sender;
            a.highestBid = amount;
            a.winningOrder = b.order;
        }
        emit Revealed(id, msg.sender, amount, leading);
    }

    /// @notice Anyone can settle, with constant gas regardless of bidder count.
    function finalize(uint256 id) external nonReentrant {
        Auction storage a = auctions[id];
        require(a.seller != address(0) && block.timestamp >= a.revealDeadline, "settlement phase");
        require(!a.finalized, "already finalized");
        a.finalized = true;
        if (a.winner != address(0)) {
            bids[id][a.winner].locked -= a.highestBid;
            proceeds[a.seller] += a.highestBid;
            emit ProceedsCredited(a.seller, id, a.highestBid);
        }
        emit Finalized(id, a.winner, a.highestBid);
    }

    function withdraw(uint256 id) external nonReentrant {
        require(auctions[id].finalized, "not finalized");
        uint256 amount = bids[id][msg.sender].locked;
        require(amount > 0, "nothing to withdraw");
        bids[id][msg.sender].locked = 0;
        emit Withdrawn(id, msg.sender, amount);
        require(token.transfer(msg.sender, amount), "token transfer failed");
    }

    function withdrawProceeds() external nonReentrant {
        uint256 amount = proceeds[msg.sender];
        require(amount > 0, "nothing to withdraw");
        proceeds[msg.sender] = 0;
        emit ProceedsWithdrawn(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "token transfer failed");
    }
}
