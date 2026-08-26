# Relaunch implementation order

Status: **planning guide**. Orders PRs. Not an implementation spec. Human prompt: `Start with R<n>` (`AGENTS.md`).

## Ground rules

- One PR, one behavioral purpose. Bundle R-items only when this file says so.
- Write `docs/relaunch/R<n>-...md` from `TASK_TEMPLATE.md` before Solidity. You may read `.cursor/relaunch-plan.md` only to draft that spec; implement from the spec.
- Ask product questions only from the **Ask** column below. Empty Ask = do not ask; implement.
- Branch before edits; stack on the latest open relaunch PR, else `main`. Commit, push, open the PR (`AGENTS.md`). Update `docs/relaunch/README.md` **Status** with the PR link and next unassigned prompt (follow-up commit if the URL was unknown before open). Stop. Remind the human of that next prompt. Human merges in order.
- Run targeted tests, then the `AGENTS.md` done-gate.
- Do not `--broadcast`. Keep OpenZeppelin `v4.9.3` until an optional late upgrade PR.

## Rootstock compiler / EVM proof

**Passed (2026-08-15).** Rootstock testnet (chain 31) accepted first-party bytecode compiled with solc **0.8.36** / `cancun`. Blockscout verified `OperationsAdmin`, `DcaManager`, and `TropykusDocHandlerMoc` at those settings. Anvil/`forge test --fork-url` is still not rskj; this testnet tx is the consensus proof. PR 3+ may merge on this pin. Do not set `prague` / `osaka` / `amsterdam`. Do not use blob opcodes.

## Product gates

PR 2 was the original decision-record slot. Record each still-open decision **before the first PR that changes its surface**. Ask **only** the gates named for the assigned PR in the table below.

- Fee model: keep linear / flatten to one rate / leave as-is for now.
- R18 packing: skip / `DcaDetails` only / `DcaDetails` plus handler per-user state.
- R19 pause: this relaunch or defer.
- Optional: R12 compound, owner sweep, on-chain deposit pause.

Defaults if the human says “use defaults”: keep OZ `v4.9.3`; skip packing (still `calldata` on handler batch arrays); defer R12, R19, owner sweep, deposit pause. Do not apply defaults unless they say so. R13 is now required and has its own migration-policy gate; R31 and R34 own their API gates.

## External lending incentives

The relaunch handlers distribute native lending interest only. They do not claim or redistribute temporary third-party incentives. Future campaign support should use off-chain forwarding directly to users; if a provider does not integrate BitChill, the handler leaves those rewards unclaimed rather than adding an approximate harvest-time allocation or an owner claim. Frontends must not present an incentive-inclusive APR as BitChill yield unless forwarding is live.

This does **not** depend on a provider response. R9 must make the handlers indexer-ready by emitting one canonical per-user virtual lending-share balance transition after every share mint or burn. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md) for the decided event shape, required emit sites, and scope boundary.

## PR order

Ask = product questions for that PR only. `Start with R2` means PR 3.

| Start with | PR | Ask |
|---|---|---|
| R23 | 1 (merged) | — |
| PR 2, decision record | 2 | Fee model, R18, R19, optionals listed above |
| R2 | 3 | none |
| R7, R11, R14 | 4 | none |
| R3, R4, R5 | 5 | Fee model if PR 2 did not record it |
| R6, R17 | 6 | none |
| R8 | 7 | none |
| R1, R20 | 8 | none |
| R24 | 9 | none |
| R15 | 10 | none |
| R22 (folders) | 11 | none |
| R22 (idle) | 12 | none |
| R21 | 13 | none |
| R16 | 14 | none |
| R22 (LayerBank) | 15 | none |
| R25 | 16 | none |
| R26 | 17 | none |
| R27 | 18 | none |
| R28 | 19 | none |
| R29 | 20 | none |
| R30 | 21 | none |
| Post-R30 architecture plan | 22 (docs only) | none; records the later gates |
| R33 | 23 | none |
| R13 | 24 | one-shot user migration: manual exit without future cooperative migration, or ship fully specified user-initiated migration now |
| R31 | 25 | individual fee setters or atomic-only fee mutation |
| R34 | 26 | schedule mutation surface; frontend/backend consumer cutover |
| R32 | 27 | none |
| R22 (deploy/CI) | 28 | none |
| R9 | 29 | R18/R19 if not recorded (ABI freeze) |
| R10 | 30 | none |
| R12, R18, R19, OZ 5.x | optional late | only if the human named that item |

### PR 1 - R23 toolchain and dependency baseline

**Merged.** First-party `0.8.36` / `cancun`. Uniswap git sources stay `=0.7.6`; `make patch-deps` remains required. OZ `v4.9.3`. Testnet proof passed.

### PR 2 - Decision record

Record the fee-model, R18 packing, and R19 pause decisions in the relevant specs before touching those surfaces.

This can be docs-only if no code is needed. If the decision is to defer an optional item, say so explicitly.

### PR 3 - R2 purchase-period UTC boundary

Implement the UTC day-boundary eligibility rule and the one-day minimum period guard.

Keep the already-landed missed-period timestamp snap.

### PR 4 - R7, R11, R14 small DcaManager fixes

Bundle these because they are small, user-facing `DcaManager` changes:

- R7: `createDcaSchedule` max-schedules check uses `>=`.
- R11: allow a schedule funded for exactly one purchase.
- R14: add `DcaManager` accumulated-rBTC balance getters.

Do not include event reshaping, pause, or storage packing unless the assigned spec explicitly says this is the ABI/layout PR.

### PR 5 - R3, R4, R5 fee handling

If the linear fee model stays, fix the combined setter ordering, enforce individual bound setters, and load fee settings once per batch.

If the fee model is flattened, this PR becomes the one-rate rewrite instead. Do not do both.

### PR 6 - R6 and R17 hot-path cleanup

Drop `nonReentrant` on `buyRbtc` / `batchBuyRbtc` and cache `SWAPPER_ROLE` on `DcaManager`. That is where the measured 3,437 gas is; both are swapper-only and write nothing after their handler call. Keep period, schedule-id, amount, lending-index, access-control, malformed-calldata, underfunded-schedule, and empty-batch checks (the last two are diagnostic, not hot-path).

Keep `nonReentrant` on **every** external function that writes `s_dcaSchedules` (`AGENTS.md` invariant 6). Removing it from user paths saves ~2,300 gas — about 1.4 cents, paid by users, not the protocol — and three review rounds produced three exploitable states trying to reason it away. A partial set is worse than none, since OZ's guard only blocks other *guarded* functions.

Schedule ids come from a monotonic `s_scheduleNonce`, never from array state (`AGENTS.md` invariant 7). `depositToken` pulls before crediting. `updateDcaSchedule` keeps its memory-copy order — the storage write was always after the pull, so reordering it was a no-op. See `R6-hot-path-cleanup.md`.

### PR 7 - R8 remove stuck-rBTC rescue

Delete the owner rescue path for another account's accumulated rBTC. Keep rBTC withdrawals paying `msg.sender`; do not add a `to` parameter.

### PR 8 - R1 and R20 integration cash accounting

Fix Sovryn for SIP-0094 and apply the broader rule that integrator return values and views are not cash.

Measure token/native balance deltas after Sovryn, Tropykus, MoC, and Uniswap operations that move funds to BitChill or to the user. Use views only to size share burns, then clamp to shares held.

**R6 leftover — clamp desync, this PR owns it:** `DcaManager._withdrawToken` / `deleteDcaSchedule` deduct the *requested* amount, then Tropykus/Sovryn `withdrawToken` may clamp to the user's lending position and pay less. That is not R1 (Sovryn `burn` return vs net). It is R20: do not treat the requested amount as cash paid. After the handler call, measure the user's token delta (or take the actual payout) and only deduct that from `tokenBalance`. Do not leave this as a footnote on R1.

### Heads-up for any future idle-funds handler

**Read this before writing a handler that holds the stablecoin instead of lending it.**

Per-user accounting for lending lives in `LendingErc20Handler.s_shares`. Idle has its own mapping in `IdleErc20Handler`. The base `TokenHandler.withdrawToken` is a bare `safeTransfer` with **no cap and no mapping behind it**, so a handler that extends `TokenHandler` without adding its own per-user tracking pays out whatever `DcaManager` asks from a pooled balance.

Lending handlers clamp a withdrawal to the caller's own position (`LendingErc20Handler.withdrawToken`) instead of reverting. That clamp is what currently bounds *every* `DcaManager` accounting bug to the user who caused it. Remove it and the same bugs become solvency bugs against other users' pooled funds. Concretely, the `updateDcaSchedule` stale-write-back reentrancy that R6 analysed is self-desync under a lending handler and a straight pool drain under an idle one.

So, for an idle-funds handler:

- It **must** carry per-user accounting and clamp `withdrawToken` to the caller's own balance, or it inherits an uncapped withdraw. R28 put that clamp on `LendingErc20Handler` for the lending twins; Idle already has its own. Do not drop the clamp from a new idle handler.
- Invariant 6 in `AGENTS.md` (comprehensive `nonReentrant` on schedule mutators) stops being cheap insurance and becomes load-bearing. Do not relax it in the same relaunch that introduces pooled idle funds.
- The R20 balance-delta work above matters more, not less: with no clamp, `DcaManager.tokenBalance` is the only thing standing between a user and the pool.

### Handler replacement — assigned to R13

R13 owns the complete `OperationsAdmin` security and lifecycle surface. A live `(token, routeIndex)` becomes add-only: governance upgrades by registering a new versioned route, while old schedules keep resolving to the old handler that holds their funds. Same-index overwrite, owner rescue, and owner-selected migration destinations are prohibited.

The remaining product gate is whether relaunch also ships a fully specified **user-initiated** migration or uses versioned routes with manual user exit/re-entry. This is a one-shot cutover decision: cooperative migration must be callable on the old immutable handler, so choosing manual exit means the handlers deployed by the relaunch cannot acquire that capability later. See [`R13-operations-admin-lifecycle.md`](./R13-operations-admin-lifecycle.md).

### PR 9 - R24 test harness matrix

Stacked on PR 8. Test/Makefile only. `make moc-sovryn` must actually run Sovryn (`BaseDeploymentTest` must not `vm.setEnv` `LENDING_PROTOCOL`). `make fork-*` must pass a single `--no-match-path`. Tropykus fork tests pin Rootstock block `8700000` (2026-04-05); kDOC mint was paused between blocks 8739512 and 8740674. See `R24-test-harness-matrix.md`.

### PR 10 - R15 withdraw-all sentinel

Add `type(uint256).max` as "withdraw this schedule's full tokenBalance." Lending-share dust is deferred, not fixed; the decision is recorded in `R15-withdraw-all-sentinel.md`.

This should follow R1/R20 so net redemption behavior is settled first.

### PR 11 - R22 repo layout preparation

Move protocol-specific sources and tests into folders:

- `src/sovryn/`
- `src/layerbank/`
- `src/idle/`
- `src/tropykus-legacy/`

Keep behavior unchanged where possible. Tropykus remains legacy code and tests, but it must not be registered in the new deployment path.

### PR 12 - R22 idle handler

Ship the index-0 idle DOC + MoC handler. Deposits stay on the handler; no lending token is minted; buys and withdrawals spend idle DOC.

Interest calls for index 0 should continue to revert. R13 later replaces the absence-of-name test with a direct lending-route flag that is always false for index 0.

### PR 13 - R21 fee-on-transfer deposits

R1 left deposit accounting as "credit the requested amount." Idle already credits the handler mapping from a balance delta; `DcaManager` still credits `depositAmount`. FOT is not a supported token class. This PR is hop-1 hygiene so a listed proxy that suddenly turns on a transfer fee cannot mint more than the handler holds and cannot freeze withdrawals. Purchases after that are not guaranteed.

`TokenHandler.depositToken` measures `balanceOf(address(this))` before/after `transferFrom` and returns the received amount. `DcaManager` create / deposit / update credits that return, and validates `purchaseAmount` against the post-deposit `tokenBalance`. Lending handlers mint from the received amount, not the requested one. A lending hop-2 lag can make `batchBuyRbtc` revert for the whole batch (named error; swapper drops the row) — same as any share shortfall. Do not change the R20 withdraw rule (principal falls by the requested amount; a fee consumes principal). Do not add recipient-side withdraw measurement.

Land this before LayerBank so the new handler copies the measured-deposit pattern. Tests: a `MockFeeOnTransferStablecoin` in the same style as `MockReentrantStablecoin` / `DepositSwapPopReentrancyTest`. See `R21-fee-on-transfer-deposits.md`.

### PR 14 - R16 redeem glossary

Rename first-party internals, events, variables, and comments so "redeem" names the token being given up. Do not rename third-party ABI functions (`redeemFreeDoc`, `redeemUnderlying`, iToken `burn`, …). No behavior change; no new tests.

PurchaseRbtc's `_redeemStablecoin` hook is "make stablecoin available to spend," not a redeem. Idle only debits a mapping. MoC's first-party wrapper spends DOC to receive rBTC. Land this before LayerBank so the new handler does not copy the current names. See `R16-redeem-glossary.md`.

This should land before the full natspec pass (R10).

### PR 15 - R22 LayerBank handler

Add LayerBank as index 1 for DOC + MoC. Use balance-delta accounting from the start (including R21 deposit returns). Add mocks or a live fork probe based on the Rootstock LayerBank **Pool / aToken** ABI (Aave-v3-style lRooDOC). Do not implement against the stale v2 Core / lToken README — that Core never listed DOC.

LayerBank owns exact per-user virtual **scaled aToken** balances and implements the shared `getUserShares(user)` getter. External incentives are out of scope: no Merkl interfaces, reward token, harvest, claim, operator, reward-debt, or unwrap logic. R9 later adds the canonical balance-transition event across the final lending-handler set; LayerBank must expose every share mutation cleanly enough for that event to cover deposits, withdrawals, interest, and single/batch purchases. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md).

Do not rename Tropykus in place and do not deploy USDRIF/Uniswap handlers for this relaunch.

### PR 16 - R25 lending redeem helper naming

Leftover from R16 (PR 14): that glossary pass still left `_burnKtoken` and a “repay” alias. Rename-only (plus tiny leaf cleanup), after LayerBank exists so all three lending handlers match. Drop `_burnKtoken` / `_burnAtoken` and `*ToRepay` locals in favor of `_redeemByUnderlying` / `_redeemByShares` (Tropykus/LayerBank) and `*ToRedeem` locals (all three). Sovryn stays one share-sized helper with a recipient overload; stop reusing `stablecoinInterestAmount` for the measured payout; rename `totalErc20InLending` → `totalStablecoinInLending`. Copy Sovryn’s `getAccruedInterest` natspec onto Tropykus/LayerBank. Drop unused `minPurchaseAmount` from Tropykus/Sovryn MoC/Dex constructors (LayerBank already omitted it); fix SovrynDocHandlerMoc’s “Tropykus' iSUSD” natspec. Also rename the shared event to `TokenLending__AmountToRedeemAdjusted` — the relaunch deploys fresh with no live log consumer, and R9 (now PR 29) freezes the event surface, so this is the last cheap moment. See `R25-lending-redeem-naming.md`.

Land before R26 and deploy/CI so neither PR freezes the old helper names.

### PR 17 - R26 share terminology

"Lending token" is not DeFi nomenclature and reads backwards — `_stablecoinToLendingToken` sounds like "the token being lent", which is the stablecoin. Aave says `aToken`, Compound (Tropykus's fork parent) says `cToken`; the recognized generic is ERC-4626's **shares**. Rename the receipt-token noun to `shares` across `ITokenLending`, `TokenLending`, and the handlers: `getUsersLendingTokenBalance` → `getUserShares`, `_stablecoinToLendingToken` / `_lendingTokenToStablecoin` → `_stablecoinToShares` / `_sharesToStablecoin`, `TokenLending__LendingTokenRedeemed(Batch)` → `…SharesRedeemed(Batch)`, `TokenLending__InsufficientLendingTokenBalance` → `TokenLending__InsufficientShares`, and Sovryn's `_redeemLendingToken` → `_redeemShares`.

Keep `ITokenLending` / `TokenLending` / `LENDING_PROTOCOL` / `LendingProtocol*Failed` — "lending" as a domain word is fine; only "lending **token**" is wrong. Keep `stablecoin` as the asset noun; do not adopt 4626's `assets`.

Land before R22 deploy/CI (now PR 28) for the same reason R25 did: that PR splits the harness where 76 of the 295 matching lines live, so renaming afterwards writes them twice. **R9 (now PR 29) is the ABI freeze** and already specifies `TokenLending__UserSharesUpdated(…, previousShares, newShares)`; until this PR reworded it, the R9 entry below also required a test asserting `newShares == getUsersLendingTokenBalance(user)` — two names for one quantity. Settle the noun before that lands. See `R26-share-terminology.md`.

### PR 18 - R27 Tropykus lending cash guards

Human reordered (2026-08-25): land R27 and R28 **before** R22 deploy/CI so the Tropykus cash bugs are fixed and the shared lending base exists before the harness/CI cutover and well before R9's ABI freeze. R27 does not depend on the new index map — Tropykus stays legacy-only either way.

After a 0 Compound `mint` code, revert `TokenLending__LendingProtocolDepositFailed` if the measured kToken delta is 0 (Sovryn `:66`, LayerBank `:80` already do). After a 0 Compound batch `redeemUnderlying` code, revert `TokenLending__ZeroStablecoinReceived` if the measured DOC delta is 0 (Sovryn `:226`, LayerBank `:284`); do not emit-and-return zero. Keep Tropykus’s single-redeem `stablecoinAmount > 0 &&` conjunct — that is the Compound analogue of LayerBank skipping a zero `Pool.withdraw`, not a third bug.

Do not extract a shared base here. See `R27-tropykus-lending-guards.md`. Must land before R28 so the base copies the aligned guards. Stack on R26 (PR 17).

### PR 19 - R28 extract `LendingErc20Handler`

Promoted from optional late (human named it for this slot). Collapse the three lending `*Erc20Handler` twins into one abstract `LendingErc20Handler is TokenHandler, TokenLending`. Idle stays out; `TokenLending` stays conversion math. Requires R27 first. Cheapest before R9 (one `UserSharesUpdated` emit site) and before R22 deploy/CI splits the harness around the old three-file shape. See `R28-lending-erc20-handler.md`.

### PR 20 - R29 hardcode each adapter’s exchange-rate scale

Sovryn and Tropykus still take `exchangeRateDecimals` as a constructor argument; LayerBank already hardcodes `RAY`. The scale is a protocol constant, not a deploy knob — passing `Constants.sol`’s `1e18` into LayerBank would size withdrawals 1e9× too large. Bind `1e18` as `EXCHANGE_RATE_DECIMALS` on the Sovryn and Tropykus adapters (same shape as LayerBank’s `RAY`). Drop the arg from those adapters, their Moc/Dex leaves, and every `new` / script call site. Do not add the arg to LayerBank. `TokenLending` still receives the value from the adapter.

Must land before R30 and R22 deploy/CI so neither inherits or freezes the extra constructor arg. Stack on R28 (PR 19, GitHub #63). See `R29-hardcode-exchange-rate-scale.md`.

### PR 21 - R30 shared rBTC purchase pipeline

Promoted from Candidates A+B in the post-R29 full-`src/` review. Move the duplicated MoC/Uniswap single and batch algorithm into `PurchaseRbtc`, with route hooks that continue to return measured native rBTC or WRBTC cash. Add a shared `StablecoinSource` declaration inherited by the purchase and funding bases so the six leaves can delete twelve forwarding resolvers.

This is behavior-preserving architecture work: no ABI, fee, allocation, event, error, constructor, slippage, or deploy changes. It is primarily a maintenance/drift win, not promised bytecode headroom; measure the concrete handlers and keep both Dex handlers below EIP-170. Give the common algorithm base-level tests plus MoC/Uniswap route-adapter coverage. See [`R30-purchase-pipeline.md`](./R30-purchase-pipeline.md).

GitHub [#65](https://github.com/BitChillRSK/dca-contracts/pull/65). Stack on R29 (PR 20, GitHub #64). Land before R22 deploy/CI (now PR 28) so the harness is split around the final purchase shape.

### PR 22 - Post-R30 architecture plan (docs only)

Resolve the former unassigned checkpoint into implementation specs and order. No Solidity or behavior changes:

- Candidate F plus the handler-replacement question becomes required [R13](./R13-operations-admin-lifecycle.md).
- Candidate E becomes [R33](./R33-uniswap-slippage-validation.md).
- Candidate C becomes [R31](./R31-handler-abi-trim.md).
- Candidate D is split into public-ABI [R34](./R34-dca-manager-abi.md) and behavior-preserving [R32](./R32-internal-cleanup.md).

The split is intentional: authority/fund lifecycle, configuration behavior, handler ABI, DcaManager ABI, and internal cleanup each receive their own review boundary. The old checkpoint is closed; none of Candidates C–F remains in limbo.

The R28 snapshot measured runtime bytecode at 21,081 bytes for `DcaManager`, 24,243 for `SovrynErc20HandlerDex`, and 24,366 for `TropykusErc20HandlerDex`. R30 changed those numbers; R31 must re-measure actual base/head sizes rather than carrying the snapshot forward as a promise.

Deliberate non-candidates remain excluded: do not merge `TokenLending` into `LendingErc20Handler`, absorb Idle into the lending base, add speculative adapter layers, or introduce proxies, delegatecall, owner rescue, or a withdrawal `to` parameter.

### PR 23 - R33 Uniswap slippage validation

Use the same settings invariant in construction and both existing setters. Raising the safety floor above the active minimum must revert without changing state. This is a small intentional owner-configuration tightening, kept separate from selector pruning. It has no gate or file overlap with R13, so landing it first keeps the rest of the stack moving while R13's migration decision is answered. See [`R33-uniswap-slippage-validation.md`](./R33-uniswap-slippage-validation.md).

### PR 24 - R13 operations authority and handler lifecycle

Remove the unused owner/admin split: production has assigned both powers to the same multisig for a year, so one owner-governance boundary is clearer than parallel `Ownable` and `AccessControl` systems. Keep the real operational separation by representing the existing multi-swapper allowlist through a narrow typed mapping.

At the same time, remove the unused string protocol registry, classify lending routes directly, and make `(token, routeIndex)` assignments add-only. An index identifies an immutable route/version, not a unique external provider. Governance deploys upgrades at new indexes; old schedules continue to resolve to the handlers holding their funds. A wrong assignment consumes its index even before use because governance cannot prove globally that a handler is empty.

Ask the migration gate as a one-shot cutover decision: cooperative migration must exist on the old immutable handler, so choosing manual exit now means the relaunch handlers cannot gain that capability later. Never allow governance to move another user's funds. See [`R13-operations-admin-lifecycle.md`](./R13-operations-admin-lifecycle.md).

### PR 25 - R31 handler ABI trim

Remove redundant handler getters and aliases before R9 freezes the shipped surface, and decide whether fee-band mutation remains available through individual setters or only the atomic setter. Preserve fee math, the 5% cap, every concrete handler constructor ABI, storage layout, and purchase behavior; remove dead stablecoin parameters only from the abstract purchase bases. Re-measure every concrete handler's selectors and runtime margin. See [`R31-handler-abi-trim.md`](./R31-handler-abi-trim.md).

### PR 26 - R34 DcaManager ABI

Consolidate duplicated schedule/read APIs, derive `withdrawTokenAndInterest` routing from the validated schedule, and decide the public schedule-mutation surface with the relaunch consumer. Keep schedule storage, purchase behavior, and invariant 6 unchanged. See [`R34-dca-manager-abi.md`](./R34-dca-manager-abi.md).

### PR 27 - R32 internal cleanup

Only after R13 and R34 settle the surrounding surfaces, remove redundant DcaManager memory copies/lookups/loops and identical exchange-rate overrides. No external selector, event, error, storage, or cash-accounting change. See [`R32-internal-cleanup.md`](./R32-internal-cleanup.md).

### PR 28 - R22 deploy scripts, constants, harness, and CI matrix

Update constants and deploy scripts for the new map:

- `0`: idle
- `1`: LayerBank
- `2`: Sovryn
- `3`: reserved for future MoC lending

Split the shared test harness so lending-share assertions live only in lending-protocol-specific tests. CI should cover `none`, `layerbank`, and `sovryn` with `SWAP_TYPE=mocSwaps`.

**Required in this PR:** round-up solvency regression on the LayerBank lane — virtual scaled books must stay ≤ handler `scaledBalanceOf` after odd-amount redeems against Aave-like round-nearest burns; the test must fail if `_stablecoinToShares` rounded down. Shared rule lives on `TokenLending`; do not re-document it only on LayerBank. See `R22-deploy-ci.md`.

Stack on R32 (PR 27). Tropykus is not in this map; R27 already corrected the legacy handler.

### PR 29 - R9 event indexing and ABI cleanup

Index only addresses and `scheduleId`. Do not index amounts, timestamps, periods, rates, strings, bytes, or arrays.

Add `TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares)` to the shared lending interface and emit it after every successful per-user virtual lending-share mutation in the shipped lending handlers. Deposits report the exact measured lending-token mint, not the stablecoin input. Withdrawals, interest, single purchases, and every buyer debit in a batch are covered; repeated users in one batch produce sequential transitions. Tests must show each `newShares` equals the per-user share getter — **renamed `getUserShares` by R26 (PR 17); write this spec against the `shares` vocabulary, not `lendingToken`** — and that replay from the fresh deployment reconstructs current balances. This is protocol observability for possible off-chain forwarding, not an on-chain external-reward integration. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md).

Do this once the shipped ABI surface is known, including any optional pause or compound-interest events that were approved.

### PR 30 - R10 natspec and comments

Rewrite first-party natspec after ABI, names, handlers, and layout are stable. Put user-facing docs on interfaces and use `@inheritdoc` in implementations.

Do not make behavior changes in this PR.

## Optional late PRs

These are deliberately after the core relaunch path:

- R12: compound accrued interest into a chosen schedule.
- R18: storage packing, only if not already chosen and implemented before layout froze.
- R19: per-schedule pause, only if not already included before event ABI froze.
- OpenZeppelin major upgrade: evaluate `v4.9.3` to latest audited `5.x` in a standalone PR.

## OpenZeppelin policy

The compiler/EVM bump and OpenZeppelin major upgrade are separate risk axes.

Keep OpenZeppelin `v4.9.3` through the required relaunch work because the repo already depends on v4 behavior for `Ownable`, `AccessControl`, `ReentrancyGuard`, `SafeERC20`, `ERC20`, `ERC20Permit`, `Math`, and tests that expect v4 revert strings. OpenZeppelin 5.x is a major-version migration with API and behavior changes; it should not be bundled into the Rootstock compiler/EVM proof or handler hardening.

If pursued, the OpenZeppelin upgrade PR should:

- update imports and constructors intentionally;
- update tests for custom errors or changed revert behavior;
- compare bytecode size and gas for deployed contracts;
- run `make check`, `make ci`, and a Rootstock testnet/fork deploy smoke;
- document why the upgrade is worth including before relaunch rather than after.
