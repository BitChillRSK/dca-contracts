# Relaunch implementation order

Status: **planning guide**. Orders PRs. Not an implementation spec. Human prompt: `Start with R<n>` (`AGENTS.md`).

## Ground rules

- One PR, one behavioral purpose. Bundle R-items only when this file says so.
- Write `docs/relaunch/R<n>-...md` from `TASK_TEMPLATE.md` before Solidity. You may read `.cursor/relaunch-plan.md` only to draft that spec; implement from the spec.
- Ask product questions only from the **Ask** column below. Empty Ask = do not ask; implement.
- Branch before edits; stack on the latest open relaunch PR, else `main`. Commit, push, open the PR (`AGENTS.md`). Update `docs/relaunch/README.md` **Status** with the PR link and next unassigned prompt (follow-up commit if the URL was unknown before open). Stop. Remind the human of that next prompt. Human merges in order.
- Run targeted tests, then the `AGENTS.md` done-gate.
- Do not `--broadcast`. Keep OpenZeppelin `v4.9.3` through R39, then R44 pins `v5.7.0`; every later PR builds on that version.

## Rootstock compiler / EVM proof

**Passed (2026-08-15).** Rootstock testnet (chain 31) accepted first-party bytecode compiled with solc **0.8.36** / `cancun`. Blockscout verified `OperationsAdmin`, `DcaManager`, and `TropykusDocHandlerMoc` at those settings. Anvil/`forge test --fork-url` is still not rskj; this testnet tx is the consensus proof. PR 3+ may merge on this pin. Do not set `prague` / `osaka` / `amsterdam`. Do not use blob opcodes.

## Final scope decisions

PR 2 was the original decision-record placeholder. GitHub PR [#74](https://github.com/BitChillRSK/dca-contracts/pull/74) supersedes it and closes every remaining gate on 2026-08-27. The remaining implementation prompts have **no product questions**.

- Keep the already-landed linear fee model.
- Delete `buyRbtc`; a length-1 `batchBuyRbtc` is the single-schedule operational path (R39).
- Upgrade to pinned OpenZeppelin `v5.7.0` (R44), then ship two-step ownership with direct initial ownership and no renunciation (R45).
- Remove `setOperationsAdmin` and pin the constructor admin (R46). Enforce one assignment per handler address (R47).
- Ship a per-token×route deposit pause (R48) and per-schedule purchase pause (R19).
- Rename the schedule struct `DcaDetails` → `DcaSchedule` (R49), pack it to three slots (R18), then finish packing in R50 (`uint64` nonce as `scheduleId`, fees, admin handler+pause, DcaManager scalars, Dex percents, `uint32` route keys on every OperationsAdmin entry). Do not narrow handler balance/share mappings.
- Do **not** ship R12 interest compounding: users can withdraw interest and deposit it explicitly, while an in-handler compound path couples principal/share accounting to a chosen schedule and expands the most sensitive cash surface.
- Do **not** add an owner sweep: pooled stablecoin and rBTC cannot be safely distinguished from liabilities, and signer-only withdrawal remains the custody boundary.
- Keep SPDX **MIT** for the relaunch. A future licensing change is a legal/product project, not latent Solidity work.
- Dex: keep the $1-listed-stable + MoC BTC/USD on-chain floor, decimal-correct it, and leave extra MEV policy to the bot (R43). LayerBank is route 1 for USDRIF/USDT0; keep Sovryn DOC at route 2; USDT0 bounds are `25e6` / `1000e6` / `100_000e6` (R36).
- Keep Tropykus local/fork lanes but no live deploy path; burn index 4 (R37).
- Replace cartesian withdraw-all semantics and keep the existing names (R38). Swapper batcher is all-or-nothing; bot EOA stays allowlisted (R42). R9 adds no extra purchase-event fields.

## External lending incentives

The relaunch handlers distribute native lending interest only. They do not claim or redistribute temporary third-party incentives. Future campaign support should use off-chain forwarding directly to users; if a provider does not integrate BitChill, the handler leaves those rewards unclaimed rather than adding an approximate harvest-time allocation or an owner claim. Frontends must not present an incentive-inclusive APR as BitChill yield unless forwarding is live.

This does **not** depend on a provider response. R9 must make the handlers indexer-ready by emitting one canonical per-user virtual lending-share balance transition after every share mint or burn. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md) for the decided event shape, required emit sites, and scope boundary.

## PR order

Ask = product questions for that PR only. `Start with R2` means PR 3.

| Start with | PR | Ask |
|---|---|---|
| R23 | 1 (merged) | — |
| PR 2, decision record | 2 (superseded by #74) | none |
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
| R35 | 27 | none |
| R32 | 28 | none |
| R22 (deploy/CI) | 29 | none |
| R39 | 30 | none (delete `buyRbtc`) |
| R44 | 31 | none (pin OpenZeppelin `v5.7.0`) |
| R45 | 32 | none (two-step ownership; direct initial owner; no renounce) |
| R46 | 33 | none (remove `setOperationsAdmin`; immutable constructor admin) |
| R47 | 34 | none (one assignment per handler address) |
| R43 | 35 | none (decisions recorded above) |
| R41 | 36 | none (reject FOT hop-1 shortfall) |
| R40 | 37 | none (`updatePurchaseAmount` / `updatePurchasePeriod`) |
| R48 | 38 | none (per-token×route deposit pause) |
| R19 | 39 | none (per-schedule purchase pause) |
| R49 | 40 | none (`DcaDetails` → `DcaSchedule`, rename-only) |
| R18 | 41 | none (`DcaSchedule` only) |
| R36 | 42 | none (decisions recorded above; kUSDRIF pause is a fork fact to measure) |
| R50 | 43 | none (`uint64` nonce id; pack fees/admin/scalars/dex; `uint32` pause keys) |
| R37 | 44 | none (keep legacy lanes; burn index 4) |
| R38 | 45 | none (replace semantics; keep names) |
| R42 | 46 | none (atomic; keep bot EOA) |
| R9 | 47 | none (no extra purchase-event fields) |
| R10 | 48 | none |

### PR 1 - R23 toolchain and dependency baseline

**Merged.** First-party `0.8.36` / `cancun`. Uniswap git sources stay `=0.7.6`; `make patch-deps` remains required. OZ `v4.9.3`. Testnet proof passed.

### PR 2 - Decision record (superseded)

The original placeholder was never needed as a separate implementation PR. GitHub PR [#74](https://github.com/BitChillRSK/dca-contracts/pull/74) records the final scope decisions above and supplies specs for every item that will ship. Rejected items are closed decisions, not a later queue.

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

Leftover from R16 (PR 14): that glossary pass still left `_burnKtoken` and a “repay” alias. Rename-only (plus tiny leaf cleanup), after LayerBank exists so all three lending handlers match. Drop `_burnKtoken` / `_burnAtoken` and `*ToRepay` locals in favor of `_redeemByUnderlying` / `_redeemByShares` (Tropykus/LayerBank) and `*ToRedeem` locals (all three). Sovryn stays one share-sized helper with a recipient overload; stop reusing `stablecoinInterestAmount` for the measured payout; rename `totalErc20InLending` → `totalStablecoinInLending`. Copy Sovryn’s `getAccruedInterest` natspec onto Tropykus/LayerBank. Drop unused `minPurchaseAmount` from Tropykus/Sovryn MoC/Dex constructors (LayerBank already omitted it); fix SovrynDocHandlerMoc’s “Tropykus' iSUSD” natspec. Also rename the shared event to `TokenLending__AmountToRedeemAdjusted` — the relaunch deploys fresh with no live log consumer, and R9 (now PR 47) freezes the event surface, so this is the last cheap moment. See `R25-lending-redeem-naming.md`.

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

At the same time, remove the unused string protocol registry, replace it with an explicit one-shot route-class registry, and make `(token, routeIndex)` assignments add-only. An index identifies an immutable route/version, not a unique external provider. Governance deploys upgrades at new indexes; old schedules continue to resolve to the handlers holding their funds. A wrong assignment consumes its index even before use because governance cannot prove globally that a handler is empty.

**No open product gates — do not ask.** Both decisions were recorded in the spec on 2026-08-26:

- **Migration gate: option (a), manual exit/re-entry.** No cooperative migration ships; these handler versions will never gain the hook. Migration would not survive the bug scenarios that motivate it (it redeems through the same path), `SovrynErc20HandlerDex` has 426 bytes of runtime margin, and a position-moving function on immutable unaudited contracts is the worst place for a bug. The work is the four conditions attached to the decision, not new code. Never allow governance to move another user's funds.
- **Idle is a route class, not index zero.** Each index registers once as idle or lending, the constructor pre-registers `0` as idle, and handler assignment requires a registered class. Without this, add-only assignment would make a buggy idle handler unrecoverable for new users on that token — because `(token, 0)` is the only idle slot and no non-zero index accepts a non-lending handler.

`DcaManager.setOperationsAdmin` and ownership-transfer hardening are explicitly **out of scope** here. Their later review is now resolved: R45 adds the acceptance flow and R46 removes the setter in favor of an immutable constructor admin. Class↔handler ERC-165 (`ITokenLending` on `assignTokenHandler`) is the same error class as a mistyped index and is **required on R31**. See [`R13-operations-admin-lifecycle.md`](./R13-operations-admin-lifecycle.md).

### PR 25 - R31 handler ABI trim

Remove redundant handler getters and aliases before R9 freezes the shipped surface, and decide whether fee-band mutation remains available through individual setters or only the atomic setter. Preserve fee math, the 5% cap, every concrete handler constructor ABI, storage layout, and purchase behavior; remove dead stablecoin parameters only from the abstract purchase bases. Re-measure every concrete handler's selectors and runtime margin.

Also close the R13 class↔handler hole: `assignTokenHandler` must match `RouteClass` to `ITokenLending` via ERC-165 (lending handlers advertise it; idle handlers must not). If Dex margin cannot absorb that after pruning, assign a follow-up spec in the same PR — do not merge with only a cutover warning. See [`R31-handler-abi-trim.md`](./R31-handler-abi-trim.md).

### PR 26 - R34 DcaManager ABI

Consolidate duplicated schedule/read APIs, derive `withdrawTokenAndInterest` routing from the validated schedule, and decide the public schedule-mutation surface with the relaunch consumer. Keep schedule storage, purchase behavior, and invariant 6 unchanged. See [`R34-dca-manager-abi.md`](./R34-dca-manager-abi.md).

### PR 27 - R35 route-index terminology

Inserted after R34 (PR 26, GitHub [#70](https://github.com/BitChillRSK/dca-contracts/pull/70)). GitHub [#71](https://github.com/BitChillRSK/dca-contracts/pull/71). Rename DcaManager's leftover `lendingProtocolIndex` to `routeIndex` so the schedule-routing noun matches `OperationsAdmin` and remains accurate for idle (non-lending) handlers. Rename-only: storage layout and remaining function selectors unchanged; the mismatch error name (and its selector) changes. See [`R35-route-index-terminology.md`](./R35-route-index-terminology.md).

Stack on R34. Land before R32 so internal cleanup is written against the final names.

### PR 28 - R32 internal cleanup

Only after R13, R34, and R35 settle the surrounding surfaces, remove redundant DcaManager memory copies/lookups/loops and identical exchange-rate overrides. No external selector, event, error, storage, or cash-accounting change. See [`R32-internal-cleanup.md`](./R32-internal-cleanup.md). The pre-existing two-routes-one-handler uniqueness hole is not part of this cleanup; R47 now closes it before new handler assignment.

### PR 29 - R22 deploy scripts, constants, harness, and CI matrix

Update constants and deploy scripts for the new map:

- `0`: idle
- `1`: LayerBank
- `2`: Sovryn
- `3`: reserved for future MoC lending

Split the shared test harness so lending-share assertions live only in lending-protocol-specific tests. CI should cover `none`, `layerbank`, and `sovryn` with `SWAP_TYPE=mocSwaps`.

**Required in this PR:** round-up solvency regression on the LayerBank lane — virtual scaled books must stay ≤ handler `scaledBalanceOf` after odd-amount redeems against Aave-like round-nearest burns; the test must fail if `_stablecoinToShares` rounded down. Shared rule lives on `TokenLending`; do not re-document it only on LayerBank. See `R22-deploy-ci.md`.

Stack on R32 (PR 28). Tropykus is not in this map; R27 already corrected the legacy handler.

### PR 30 - R39 remove `buyRbtc`

Delete `DcaManager.buyRbtc` and `PurchaseRbtc.buyRbtc`. Production uses `batchBuyRbtc`; a length-1 batch is the remaining one-schedule path. The single selector is cheaper for one schedule, so R39 must record an apples-to-apples gas delta before deletion; the plan knowingly accepts that rare overhead in exchange for one cash path and freed DcaManager/Dex bytecode before R9 spends it on share events. See [`R39-remove-single-buy.md`](./R39-remove-single-buy.md).

This goes first because it removes the dead purchase branch and creates bytecode headroom before R43 changes `PurchaseUniswap` and before R36 adds the final Dex handler.

**Must land before R9 (PR 47).**

### PR 31 - R44 OpenZeppelin 5.7 upgrade

Pin OpenZeppelin Contracts `v5.7.0` and migrate imports, constructors, libraries, mocks, and exact revert assertions without adding BitChill behavior. Compare sizes, gas, and storage layouts. The relaunch is a fresh deployment, so this is the correct point to take the supported major before later PRs build on it. See [`R44-openzeppelin-5-upgrade.md`](./R44-openzeppelin-5-upgrade.md).

R39 lands first so the migration measures the batch-only bytecode. R45 depends on OZ5's ownership implementation.

### PR 32 - R45 two-step ownership

Use one shared `Ownable2Step`-based governance policy for DcaManager, OperationsAdmin, and production handlers: pass the intended owner at construction, require acceptance for future transfers, and forbid renunciation. Update every deploy path and re-measure EIP-170 margin. See [`R45-two-step-ownership.md`](./R45-two-step-ownership.md).

### PR 33 - R46 pin OperationsAdmin

Make DcaManager's constructor-supplied OperationsAdmin immutable and remove `setOperationsAdmin` plus its event. Whole-registry replacement bypasses R13's add-only/versioned-route rule and can redirect every live schedule. Keep the canonical getter. See [`R46-pin-operations-admin.md`](./R46-pin-operations-admin.md).

### PR 34 - R47 handler-address uniqueness

An OperationsAdmin may assign each handler address exactly once. This closes the cross-route principal/share hole: DcaManager locks principal per route, while handler shares are per handler. The stronger one-assignment rule also prevents reuse across tokens or route classes, for which the handler has no keyed accounting. See [`R47-handler-address-uniqueness.md`](./R47-handler-address-uniqueness.md).

### PR 35 - R43 dex path review (peg, slippage, MEV)

Dex becomes a production venue (USDRIF + USDT0 on LayerBank). Review `PurchaseUniswap` before R36 copies it and before R9 freezes it: the $1-stable assumption against the MoC BTC/USD oracle, how `amountOutMinimum` is built, the unused-at-swap-time safety-check, SwapRouter02’s missing deadline, and Rootstock MEV. The current min-out formula is 18-decimal; **USDT0 is 6 decimals** and cannot ship on it. Implement the recorded decisions in this PR (minimum: decimal scaling if the peg is kept). See [`R43-dex-path-review.md`](./R43-dex-path-review.md).

This deliberately follows R39 so the reviewed Dex bytecode no longer contains the single-buy branch, and it deliberately precedes R36 so the new handler consumes settled shared swap behavior.

**Must land before R36 (PR 42) and R9 (PR 47).**

**Decided:** keep the listed-stable $1 assumption plus MoC BTC/USD; keep a decimal-correct on-chain oracle floor; do not add a handler deadline/private-relay dependency. Bot policy may tighten the floor operationally.

### PR 36 - R41 reject fee-on-transfer deposits

Keep R21’s hop-1 measurement; revert `TokenHandler__DepositAmountMismatch` if `received != requested`. Listed stables are 1:1; a surprise transfer fee fails closed instead of crediting a shortfall. New custom error is ABI, so this is pre-freeze. Land it before R36 so the new USDT0/USDRIF deployments start with the settled deposit policy. See [`R41-reject-fot-deposits.md`](./R41-reject-fot-deposits.md).

### PR 37 - R40 `updatePurchaseAmount` / `updatePurchasePeriod`

Rename `setPurchaseAmount` → `updatePurchaseAmount` and `setPurchasePeriod` → `updatePurchasePeriod`. Events become `PurchaseAmountUpdated(user, scheduleId, previousAmount, newAmount)` and `PurchasePeriodUpdated(user, scheduleId, previousPeriod, newPeriod)`, with neither amount nor period indexed (R9 rule). Both mutators only ever edit a schedule `createDcaSchedule` already wrote, so both read as updates; doing them together breaks the ABI once instead of twice. Combined amount+period edits remain two transactions. See [`R40-update-purchase-period.md`](./R40-update-purchase-period.md).

**Must land before R9 (PR 47).** Frontend follow-up required.

### PR 38 - R48 deposit pause

Add a governance circuit breaker per `(token, routeIndex)`: block only `createDcaSchedule` and `depositToken` before cash moves. Purchases, configuration, withdrawals, interest/rBTC claims, and deletion remain available. This replaces the vague global "on-chain deposit pause" idea with a narrow incident-control surface. The surface is `setDepositsPaused` / `areDepositsPaused`; R19's user-owned `setSchedulePaused` stops purchases, so the two need no extra qualifier. See [`R48-deposit-pause.md`](./R48-deposit-pause.md).

### PR 39 - R19 per-schedule purchase pause

Add user-owned `setSchedulePaused(..., bool)`. A paused schedule cannot appear in a successful `batchBuyRbtc`, but every deposit/configuration/exit path remains available. Add the final schedule field before packing. See [`R19-schedule-pause.md`](./R19-schedule-pause.md).

### PR 40 - R49 rename `DcaDetails` to `DcaSchedule`

Rename-only. `Details` is a noise word; the struct is the schedule, and every other identifier
around it already says so (`s_dcaSchedules`, `createDcaSchedule`, `getDcaSchedule`, `scheduleId`,
`scheduleIndex`, `setSchedulePaused`), including the local variables holding the type. Same class of
correction as R26 and R35.

No selector, event, error, storage-layout, or behavior change — verified, not assumed, by diffing
`forge inspect` `methodIdentifiers` (byte-identical) and `storageLayout` (identical slots; only the
type label moves). `DcaSettings` was rejected: the struct carries `tokenBalance` and
`lastPurchaseTimestamp`, which are protocol-written state, and naming it after its config half
invites the stale-write-back hazard R6 analysed.

Deliberately before R18 so the packing PR is written against the final name instead of rewriting the
same lines twice, and well before R9's freeze. See [`R49-schedule-struct-name.md`](./R49-schedule-struct-name.md).

### PR 41 - R18 DcaSchedule storage packing

Pack `DcaSchedule` into three slots with checked widths: two `uint128` amounts; `uint32` period, `uint48` timestamp, `uint32` route, and `bool paused`; then `bytes32 scheduleId`. External function inputs remain `uint256`; casts are checked before cash/state mutation. Handler balance/share mappings stay `uint256` because narrowing them saves no slot and increases financial risk. Further packing (nonce as `uint64` id, fees, admin, scalars, dex percents, remaining `uint32` route keys) is R50. See [`R18-storage-packing.md`](./R18-storage-packing.md).

### PR 42 - R36 LayerBank dex stables (USDRIF + USDT0)

Ship `LayerBankErc20HandlerDex` (`LayerBankErc20Handler` + `PurchaseUniswap`, constructor-only, modelled on `SovrynErc20HandlerDex`) and deploy it twice: USDRIF (replacing `TropykusErc20HandlerDex`) and USDT0 (new listing). Same bytecode; config differs. Add a `dex-layerbank` lane to the Makefile and CI for both `STABLECOIN_TYPE=USDRIF` and `STABLECOIN_TYPE=USDT0`.

R22 (PR 29) took Tropykus off the production **MoC** map but it is still live on the **dex** map: `DeployUsdrifHandler` and the `DeployDexSwaps` live branch both deploy Tropykus dex handlers. LayerBank lists USDRIF **and** USDT0. R22 listed "LayerBank Uniswap / USDRIF" as out of scope; this is that deferred item plus the USDT0 twin.

USDT0 is 6 decimals (`0x779Ded0c9e1022225f8E0630b35a9b54bE713736`). Do not pass `Constants.sol`'s 18-decimal `MIN_PURCHASE_AMOUNT` / `FEE_PURCHASE_*` into the USDT0 handler. Fee bounds are per-handler constructor args; the min is `DcaManager.setTokenMinPurchaseAmount`. **Blocked on R43:** `_getAmountOutMinimum` currently treats stablecoin units as 18-decimal USD.

Lands before R9 and R10 on purpose: the event freeze must exercise the final shipped lending-handler set, including both LayerBank Dex deployments, and the natspec pass must include the new handler and deploy surface instead of requiring a one-off style exception.

**Decided:** LayerBank is index 1 for USDRIF and USDT0; keep the Sovryn DOC arm at index 2; USDT0 min/fee magnitudes are `25e6` / `1000e6` / `100_000e6`. Probe and record kUSDRIF's live pause status; that is a fact, not a product gate. See `R36-layerbank-usdrif-dex.md`.

### PR 43 - R50 packing follow-up

Two-slot `DcaSchedule` with a public `uint64 scheduleId` equal to the monotonic nonce (no keccak). Pack `FeeHandler` (rates + collector; two `uint128` bounds), OperationsAdmin handler+pause into one `TokenRoute` value, DcaManager protocol scalars + nonce into one slot, and the two Uniswap slippage percents into one slot. Apply R18’s `toUint32()` bound to `setDepositsPaused` and every other OperationsAdmin route-index argument (R18 review: pause still keyed the mapping with raw `uint256`). Keep `s_scheduleNonce`; do not bitmap-pack address flags; do not narrow handler financial mappings. See [`R50-packing-follow-up.md`](./R50-packing-follow-up.md).

**Must land before R9 (PR 47).** ABI: `bytes32 scheduleId` → `uint64` on every function, event, and error that carries it.

### PR 44 - R37 retire Tropykus from every live path

Remove Tropykus from every live deploy branch, move its deploy scripts under `script/tropykus-legacy/`, and move `TROPYKUS_INDEX` from `script/Constants.sol` to `test/Constants.sol` so a future `script/` file naming it fails to compile. `TROPYKUS_STRING` stays in `script/Constants.sol` — `MocHelperConfig` / `DexHelperConfig` need it to select mocks for the local lane, and neither uses the index.

**Blocked on R36 (PR 42).** Removing the Tropykus dex arm before a LayerBank USDRIF handler exists deletes USDRIF DCA. USDT0 is new and is not on Tropykus; it does not change this block. Git-stack on R50 (PR 43) so packing lands first.

Handler contracts and their tests stay; `make moc-tropykus` / `dex-tropykus` / `fork-tropykus` keep their mock and live coverage of `LendingErc20Handler` through a second adapter. A sentinel "unreachable" index was considered and rejected: `routeIndex` is an unpacked `uint256`, `s_routeClass` is a sparse mapping, and nothing in `src/` enumerates indexes, so a large number enforces nothing. Compilation scope is the enforcement. Completes the `src/` / `script/` split that R22-repo-layout (PR 11) started.

**Decided:** keep the local/fork Tropykus lanes and keep index 4 burned. See `R37-retire-tropykus-live-paths.md`.

### PR 45 - R38 zip withdraw-all route pairs

Replace the `tokens × routeIndexes` cartesian product in `withdrawAllAccumulatedInterest` and `withdrawAllAccumulatedRbtc` with positional `(token, routeIndex)` pairs, so a caller can name exactly the routes it holds a balance on. See [`R38-withdraw-all-route-pairs.md`](./R38-withdraw-all-route-pairs.md).

R36 and R37 now land first, so this PR is written and tested against the final production route topology rather than asking an implementation decision from a later PR. Even if the shipped maps do not contain a mixed-token/mixed-route partial grid, the add-only route registry can acquire one later and the cartesian API still cannot express a set of pairs.

Not a live cash defect after R37: the only handler whose no-op call does real work is Tropykus, whose `_exchangeRate()` override is the state-changing `exchangeRateCurrent()`; everything else inherits the view default. This remains required because R9 freezes the signature for the life of the deployment.

**Must land before R9 (PR 47).**

**Decided:** replace the cartesian semantics without a legacy alias and keep the `withdrawAllAccumulated*` names.

### PR 46 - R42 swapper batcher

A dedicated contract, allowlisted as a swapper, that forwards several `DcaManager.batchBuyRbtc` calls in one tx (one group per token×route). No `multicall` on `DcaManager`. Holds no user funds. Land it after the final route map and before the freeze so R9 audits the complete first-party surface and R10 documents it. See [`R42-swapper-batcher.md`](./R42-swapper-batcher.md).

**Decided:** all-or-nothing, and keep the bot EOA allowlisted for break-glass/single-handler retries.

### PR 47 - R9 event indexing and ABI freeze

Index every existing scalar `address` and `scheduleId`, and index nothing else. Do not index amounts, timestamps, periods, rates, strings, bytes, arrays, address arrays, or encoded paths. Do not shorten diagnostic custom-error argument lists (R6).

Add `TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares)` to the shared lending interface and emit it after every successful per-user virtual lending-share mutation in the shipped lending handlers. Deposits report the exact measured lending-token mint, not the stablecoin input. Withdrawals, interest, and every buyer debit in a batch are covered; repeated users in one batch produce sequential transitions. Tests must show each `newShares` equals `getUserShares(user)` and that replay from a fresh deployment reconstructs current balances. The shipped set now includes the LayerBank Dex handler added by R36. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md) and [`R9-event-indexing.md`](./R9-event-indexing.md).

Add `FeeHandler__FeeTransferred(token, collector, amount)` from `_transferFee` when the fee is non-zero (one event per batch for the aggregated fee). Per-user rBTC in a batch is already `PurchaseRbtc__RbtcBought` — that is a monitoring consumer, not a new event.

R18/R19/R49/R50 already landed. Add no extra purchase-event fields.

### PR 48 - R10 natspec and comments

Rewrite first-party natspec only after ABI, names, handlers, route maps, and the batcher are stable. Put user-facing docs on interfaces and use `@inheritdoc` in implementations.

Do not make behavior changes in this PR.

### PR 49 - R42 integrate grouped purchases in DcaManager ([#101](https://github.com/BitChillRSK/dca-contracts/pull/101))

Follow up the standalone R42 batcher after measuring the completed manager: move
`batchBuyRbtcAcrossHandlers` into `DcaManager`, authenticate once, and loop the same one-handler helper
so each handler's batch completes its checks, effects, and handler call before the next. Remove
the standalone contract, interface, and deploy add-on. The original one-handler selector stays
available for bot retries. See [`R42-swapper-batcher.md`](./R42-swapper-batcher.md).

**Decided:** the final manager is not planned to grow further, so the recurring hot-path saving is
worth the remaining EIP-170 margin. Grouped calls remain atomic and the bot EOA remains allowlisted.
The cheaper one-loop implementation is preferred over a bundle-wide CEI two-pass: handlers are
BitChill-deployed, purchase paths stay `onlySwapper`, and the extra pass costs gas on every tick.

## Closed non-implementation decisions

There is no optional-late queue. Items either have an ordered spec above or are closed here:

- **R12 compound interest into a chosen schedule — rejected.** The existing explicit withdraw-interest then deposit flow is legible and user-controlled. An atomic compound path must reconcile per-handler shares with per-route/per-schedule principal and adds a new cash-moving entry point to immutable handlers for convenience, not solvency.
- **Owner sweep — rejected.** A pooled balance cannot prove which tokens are harmless dust versus user liabilities. Governance must not gain a path around signer-only withdrawals.
- **Handler per-user storage packing — rejected.** Each mapping value is already one slot and contains a financial amount. Narrowing it saves no slot across mapping entries.
- **Address-keyed bool bitmaps — rejected.** `s_swappers` and `s_handlerAssigned` are sparse address keys; they never share a word, so a bitmap is extra math for the same SLOAD. R50 packs the `(token, routeIndex)` handler+pause pair instead.
- **SPDX change — rejected for this relaunch.** Keep the repository's existing MIT license. Re-licensing requires an explicit legal/product process outside the contract implementation stack.

## OpenZeppelin policy

The compiler/EVM bump and OpenZeppelin major upgrade remain separate risk axes. R23 already proved solc `0.8.36` / `cancun` on Rootstock. R44 is now a required standalone dependency migration from `v4.9.3` to pinned stable `v5.7.0`, after R39 removes dead bytecode and before later security/ABI work.

R44 must update imports/constructors intentionally, retain exact error assertions, compare runtime/gas/storage, and run the full local/CI/fork matrix. It must not add Ownable2Step or BitChill behavior; R45 owns that reviewable behavior change.
