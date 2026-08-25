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

## Product gates (PR 2)

Record these **before the first PR that changes fee logic, `DcaDetails`, handler per-user storage, or event ABI** (not before R2). If the human starts that later PR and PR 2 is not merged, ask **only** the gates that PR needs.

- Fee model: keep linear / flatten to one rate / leave as-is for now.
- R18 packing: skip / `DcaDetails` only / `DcaDetails` plus handler per-user state.
- R19 pause: this relaunch or defer.
- Optional: R12 compound, R13 admin, owner sweep, on-chain deposit pause.

Defaults if the human says “use defaults”: keep OZ `v4.9.3`; skip packing (still `calldata` on handler batch arrays); defer R12, R13, R19, owner sweep, deposit pause. Do not apply defaults unless they say so.

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
| R22 (deploy/CI) | 17 | none |
| R9 | 18 | R18/R19 if not recorded (ABI freeze) |
| R10 | 19 | none |
| R12, R13, R18, R19, OZ 5.x | optional late | only if the human named that item |

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

Per-user accounting exists only in `TropykusErc20Handler.s_kTokenBalances` and `SovrynErc20Handler.s_iSusdBalances`. The base `TokenHandler.withdrawToken` is a bare `safeTransfer` with **no cap and no mapping behind it**, so a handler that extends `TokenHandler` without adding its own per-user tracking pays out whatever `DcaManager` asks from a pooled balance.

Both lending handlers clamp a withdrawal to the caller's own position (`TropykusErc20Handler.sol:79-82`, `SovrynErc20Handler.sol:79-82`) instead of reverting. That clamp is what currently bounds *every* `DcaManager` accounting bug to the user who caused it. Remove it and the same bugs become solvency bugs against other users' pooled funds. Concretely, the `updateDcaSchedule` stale-write-back reentrancy that R6 analysed is self-desync under a lending handler and a straight pool drain under an idle one.

So, for an idle-funds handler:

- It **must** carry per-user accounting and clamp `withdrawToken` to the caller's own balance, or it inherits an uncapped withdraw. Consider making the base class enforce this rather than leaving it to each subclass.
- Invariant 6 in `AGENTS.md` (comprehensive `nonReentrant` on schedule mutators) stops being cheap insurance and becomes load-bearing. Do not relax it in the same relaunch that introduces pooled idle funds.
- The R20 balance-delta work above matters more, not less: with no clamp, `DcaManager.tokenBalance` is the only thing standing between a user and the pool.

### Open question — handler replacement in `OperationsAdmin`

**Not assigned to a PR. Decide before the relaunch cutover; see the deadline note below.**

`OperationsAdmin.assignOrUpdateTokenHandler` gives the same ceremony to two very different operations: assigning a handler where none exists, and overwriting one that is already live and holding user funds. Only the first is safe. After a replacement, `DcaManager` routes to the new handler while the old one still holds every user's position (kDOC, iSUSD, or idle stablecoin) with no way to get it out — the new handler's per-user mappings are empty, so withdrawals clamp to zero or revert.

This is **not specific to the idle handler**. Stranded kDOC is user principal on exactly the same terms as stranded DOC; the idle handler was just where the question surfaced. Any note or fix should be written against handlers in general.

Two constraints make this harder than it looks, and they pull in opposite directions:

- **Remediation is deliberately unavailable.** R8 removed the owner's power over another account's funds to satisfy invariant 3. A rescue or admin-driven migration entry point that drains the old handler reintroduces precisely that privilege. Do not solve it that way.
- **Prohibition is unavailable too.** Handlers are immutable and unproxied (see R8), so replacing the contract *is* the only upgrade path. `assignOrUpdate` cannot simply become assign-once.

So the fix has to be preventive and has to preserve replacement. Options worth weighing when this gets picked up:

- Split the entry point: `assignTokenHandler` reverts when a handler is already set, and a separate `replaceTokenHandler` carries the risk in its name. This is only fat-finger protection — it does **not** stop funds being stranded by an intentional replacement — but it is cheap and removes the silent-overwrite footgun.
- Give handlers a cooperative migration path (old handler pushes positions to the new one on its own authority, no owner destination). This actually solves stranding, but it requires the capability to exist in the *old* handler, so it only protects handlers deployed after the change.
- Accept the current behavior and write the operational procedure down instead: users withdraw, then the handler is swapped, with a documented drain-first sequence.

**Deadline, and it is asymmetric** (same argument as R8): anything needing handler cooperation must ship before the relaunch cutover, because afterwards it means new handler contracts and a user migration. The `assignTokenHandler` / `replaceTokenHandler` split is admin-side only and stays cheap indefinitely. If only one thing gets done, the ordering follows from that.

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

Interest calls for index 0 should continue to revert because no protocol name is registered for index 0.

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

LayerBank owns exact per-user virtual **scaled aToken** balances and implements the shared `getUsersLendingTokenBalance(user)` getter. External incentives are out of scope: no Merkl interfaces, reward token, harvest, claim, operator, reward-debt, or unwrap logic. R9 later adds the canonical balance-transition event across the final lending-handler set; LayerBank must expose every share mutation cleanly enough for that event to cover deposits, withdrawals, interest, and single/batch purchases. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md).

Do not rename Tropykus in place and do not deploy USDRIF/Uniswap handlers for this relaunch.

### PR 16 - R25 lending redeem helper naming

Leftover from R16 (PR 14): that glossary pass still left `_burnKtoken` and a “repay” alias. Rename-only, after LayerBank exists so all three lending handlers match. Drop `_burnKtoken` / `_burnAtoken` and `*ToRepay` locals in favor of `_redeemByUnderlying` / `_redeemByShares` (Tropykus/LayerBank) and `*ToRedeem` locals (all three). Sovryn stays one share-sized helper with a recipient overload; stop reusing `stablecoinInterestAmount` for the measured payout; rename `totalErc20InLending` → `totalStablecoinInLending`. Copy Sovryn’s `getAccruedInterest` natspec onto Tropykus/LayerBank. Do not rename `TokenLending__AmountToRepayAdjusted`. See `R25-lending-redeem-naming.md`.

Land before deploy/CI so the index-map PR does not freeze the old helper names.

### PR 17 - R22 deploy scripts, constants, harness, and CI matrix

Update constants and deploy scripts for the new map:

- `0`: idle
- `1`: LayerBank
- `2`: Sovryn
- `3`: reserved for future MoC lending

Split the shared test harness so lending-token assertions live only in lending-protocol-specific tests. CI should cover `none`, `layerbank`, and `sovryn` with `SWAP_TYPE=mocSwaps`.

**Required in this PR:** round-up solvency regression on the LayerBank lane — virtual scaled books must stay ≤ handler `scaledBalanceOf` after odd-amount redeems against Aave-like round-nearest burns; the test must fail if `_stablecoinToLendingToken` rounded down. Shared rule lives on `TokenLending`; do not re-document it only on LayerBank. See `R22-deploy-ci.md`.

### PR 18 - R9 event indexing and ABI cleanup

Index only addresses and `scheduleId`. Do not index amounts, timestamps, periods, rates, strings, bytes, or arrays.

Add `TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares)` to the shared lending interface and emit it after every successful per-user virtual lending-share mutation in the shipped lending handlers. Deposits report the exact measured lending-token mint, not the stablecoin input. Withdrawals, interest, single purchases, and every buyer debit in a batch are covered; repeated users in one batch produce sequential transitions. Tests must show each `newShares` equals `getUsersLendingTokenBalance(user)` and that replay from the fresh deployment reconstructs current balances. This is protocol observability for possible off-chain forwarding, not an on-chain external-reward integration. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md).

Do this once the shipped ABI surface is known, including any optional pause or compound-interest events that were approved.

### PR 19 - R10 natspec and comments

Rewrite first-party natspec after ABI, names, handlers, and layout are stable. Put user-facing docs on interfaces and use `@inheritdoc` in implementations.

Do not make behavior changes in this PR.

## Optional late PRs

These are deliberately after the core relaunch path:

- R12: compound accrued interest into a chosen schedule.
- R13: simplify or redesign `OperationsAdmin` owner/admin/swapper roles.
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
