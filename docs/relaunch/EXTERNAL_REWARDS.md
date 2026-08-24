# External lending rewards and forwarding

Status: **decision record** (2026-08-24). Applies to the relaunch lending handlers and the R9 event/ABI pass.

## Decision

BitChill lending handlers distribute the lending protocol's native interest only. They do **not** claim, custody, unwrap, index, or redistribute temporary third-party incentives such as Merkl campaigns.

The preferred path for a supported external campaign is off-chain reward forwarding: the campaign indexer reconstructs each BitChill user's time-weighted virtual lending-token balance and credits that user directly. This keeps reward proofs, Distributor/operator permissions, campaign-specific tokens, keepers, and reward liabilities out of immutable handler contracts.

BitChill does not wait for a forwarding provider before shipping a handler. If a provider cannot or will not integrate BitChill, rewards attributed to the pooled handler position remain unclaimed. They do not become an owner fee or an approximately distributed current-holder reward. Product surfaces must describe BitChill yield as native lending yield and must not advertise an incentive-inclusive APR unless forwarding for that campaign is actually live.

## Why there is no on-chain reward index

A MasterChef-style index is not fair when rewards accrue off-chain and reach the handler later through an asynchronous claim. A user can hold shares while rewards are earned and exit before the claim; a new depositor present at harvest would then receive the earlier user's rewards. Updating the index only when tokens arrive allocates by shares at claim time, not shares over the earning period.

Solving that mismatch on-chain would require campaign-aware historical checkpoints, claims, or another trusted allocation layer. That is a separate reward protocol, not part of a lending handler.

## Indexer-ready lending-share history

Future forwarding must not depend on transaction traces or on reconstructing lending-token exchange rates. Starting from the fresh relaunch deployment, an indexer must be able to replay one canonical event and recover the exact virtual lending-token balance BitChill assigns to every user after every mutation.

R9 must add this shared event to `ITokenLending`:

```solidity
event TokenLending__UserSharesUpdated(
    address indexed user,
    uint256 previousShares,
    uint256 newShares
);
```

Only `user` is indexed, in line with the event-indexing rule. Block number, timestamp, transaction index, and log index already supply ordering and time; the event must not duplicate them.

Every lending handler must emit the event after each successful change to its per-user virtual lending-share mapping:

- a deposit, using the lending-token balance delta actually minted to the handler;
- a normal stablecoin withdrawal;
- an interest withdrawal;
- a single rBTC purchase;
- each per-user debit in a batch purchase, including sequential updates when the same user appears more than once.

`previousShares` lets an indexer detect a missed or inconsistent transition. `newShares` is the canonical post-state and must equal `getUsersLendingTokenBalance(user)` after the transaction. Reverted mutations produce no lasting event.

No new on-chain `totalShares` counter is required for forwarding. An indexer can sum the latest per-user balances from the event stream and cross-check individual balances through the existing getter. The lending token's `balanceOf(handler)` remains an independent aggregate solvency check, subject to the handler's documented rounding behavior.

## Existing events are not a substitute

- `TokenHandler__TokenDeposited` identifies the user but reports stablecoin received, not the exact number of lending shares minted at the then-current exchange rate.
- `TokenLending__LendingTokenRedeemed` reports exact per-user share burns, including batch debits, but there is no corresponding exact share-mint event.
- `DcaManager` events report schedule principal in underlying stablecoin. Schedule principal is not a lending-share balance.
- `getUsersLendingTokenBalance(user)` exposes current state, not the historical time-weighted balance required for forwarding.

R9 therefore owns the canonical balance-transition event in addition to correcting which existing event fields are indexed. Merely removing `indexed` from numeric fields is not enough.

## Scope boundaries

- R22 LayerBank implements lending and per-user share accounting only. It does not add Merkl interfaces, proofs, Distributor calls, operators, reward tokens, harvest functions, reward debt, or WRBTC unwrapping.
- R9 adds the protocol-neutral event across the shipped lending handlers and tests every share-changing path. It does not add an external-reward integration.
- A future forwarding provider may consume the event and getter without requiring a handler upgrade. Provider-specific API or campaign work stays off-chain.
