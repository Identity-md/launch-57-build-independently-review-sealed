# Bid sealed auction

BID is a fixed-supply ERC-20: **Bid / BID**, 18 decimals, exactly 1,000,000,000 tokens (10^27 minor units). Its zero-argument constructor mints everything to the deploying caller, including when that caller is ProjectFactory. There is no later mint, burn, owner, administrator, fee, upgrade, or initialization call. The application constructor is `SealedBidAuction(address token_)`; launch.json binds that sole argument to `$token`.

## Auction lifecycle

1. A seller calls `list(bytes32 itemId, uint256 reserve, uint256 deadline)`. Amounts are BID minor units; deadlines are Unix seconds and must be in the future. Each listing gets a new numeric auction ID. The item ID is a descriptive identifier, not an escrowed NFT or proof of ownership. Duplicate item IDs are permitted.
2. Before the deadline a nonseller approves the application and calls `commit(id, digest, lockAmount)`, once per bidder per auction. The lock must be positive. Compute the digest with `commitmentHash`, equivalent to `keccak256(abi.encode(chainId, auctionAddress, auctionId, bidderAddress, amount, salt))`. Use a cryptographically random 32-byte salt and retain it privately. Commitments cannot be replaced or cancelled. Locks are public; overcollateralizing can hide the exact bid. Never send tokens directly to the application.
3. From `deadline` inclusive until `deadline + 86400` exclusive, call `reveal(id, amount, salt)`. A valid bid is positive, at least the reserve, within its lock, and matches its digest. Bad reveals revert without changing the lock and may be retried during the window. Highest valid bid wins; equal bids favor the earlier commitment, regardless of reveal order. Sellers cannot bid from their seller address, but identity or sybil resistance is not provided.
4. At or after the reveal deadline, anyone calls `finalize(id)`. This requires constant work regardless of bidder count. It deducts the winning price from the winner's lock and credits the seller's withdrawable proceeds. With no valid reveal, there is no winner or payment. Finalization makes no token call.
5. The seller calls `withdrawProceeds()` to receive accumulated proceeds. Each bidder calls `withdraw(id)` to receive its remaining lock: the entire amount for all losers and non-revealers, excess only for the winner. Zero claims and duplicate withdrawals revert. No one may withdraw another account's claim. Token failures roll back claims, allowing retries.

All persistent business-state transitions emit events. All mutating entry points share a reentrancy guard; token transfers occur after accounting changes. Successful settlement is independent of seller activity. Each user's withdrawal needs its own transaction and gas; there is no automatic keeper, timeout cancellation, privileged refund, or force-payment path.

## Assumptions and responsibilities

This contract auctions an **off-chain item identifier**. It cannot enforce ownership, shipping, title transfer, uniqueness, or seller honesty. Users must arrange item verification and delivery externally before bidding. Payment is unconditional on delivery once the winning bid is finalized. This is unsuitable for trustless physical-item commerce without an additional delivery arrangement.

Revealing is optional with no non-reveal penalty, as all other bidders are entitled to full refunds. Strategic withholding is possible. Bids and salts become public when revealed; small or reused salts are unsafe. Bidders must retain salts, reveal well before the deadline, and withdraw after settlement. Timestamps are consensus timestamps, not guaranteed wall-clock schedules. Chain ID changes invalidate previously computed commitments. There is no administrative recovery if a user loses access or transfers tokens directly to the contract; unsolicited transfers remain stranded.

Only the supplied immutable, exact-transfer BID is supported. The constructor rejects addresses without code, but cannot prove arbitrary token behavior. Fee-on-transfer, rebasing, false-accounting, callback-dependent, or no-return tokens are unsupported. The malicious-token tests establish guard and rollback behavior, not safety with dishonest currencies. There is no sweep function, ETH entry point, or platform fee.

## Build and verification

Use Foundry with Solidity **0.8.26** installed in its normal version cache. foundry.toml pins a version, not an executable path, uses Cancun, optimization (200 runs), and `bytecode_hash = "none"`. forge-std v1.9.7 source and licenses are vendored in lib/forge-std; no submodules, package installation, network, FFI, or filesystem permissions are needed by the build or tests. The compiler and Foundry are execution-profile tools, not project dependencies.

```
forge build --offline
forge test --offline
forge fmt --check
```

Tests cover supply, transfers, permissions, unsupported admin selectors, phase boundaries, duplicates, reserve and collateral checks, ties, domain separation, concurrent auctions, conservation fuzzing, seller and bidder claims, malicious callbacks, and false/reverting token transfers. The provided protected checks were read as acceptance inputs; they require verifier-supplied deployment environment variables and are not claimed as executed by the ordinary local suite.

## Sepolia release

launch.json describes chain 11155111, token artifact `src/Bid.sol:Bid` with no arguments, then the unique application `src/SealedBidAuction.sol:SealedBidAuction` with `["$token"]`. There are no owner arguments or privileged beneficiaries. The native-ETH pool parameters are fee 3000, tick spacing 60, initial sqrtPriceX96 79228162514264337593543950336; this is a configuration value, not a valuation. Initial launch supply belongs to the factory for protocol allocation and liquidity; application construction does not move it.

The admitted deployer must validate manifest fields against its release schema, build and attest these exact artifacts, check Sepolia policy and compiler settings, resolve `$token` to the newly deployed BID, and verify constructor arguments and final bytecode. A separate contributor must review source plus final manifest before admission; see REVIEW.md for the independent review performed in this assignment. Tests and this review are not a professional security audit. No contributor script broadcasts, accesses wallet keys, or deploys contracts. The authorized deployer alone performs release transactions. Sellers choose realistic commit deadlines; bidders and sellers operate the lifecycle above, and any participant may finalize expired auctions.
