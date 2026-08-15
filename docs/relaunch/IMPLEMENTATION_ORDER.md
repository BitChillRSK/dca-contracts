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
| R15 | 9 | none |
| R22 (folders) | 10 | none |
| R22 (idle) | 11 | none |
| R22 (LayerBank) | 12 | none |
| R22 (deploy/CI) | 13 | none |
| R9 | 14 | R18/R19 if not recorded (ABI freeze) |
| R16 | 15 | none |
| R10 | 16 | none |
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

Drop `nonReentrant` on purchase and on CEI-clean withdraw/interest paths, and cache `SWAPPER_ROLE` on `DcaManager`. Keep it on `depositToken` and `deleteDcaSchedule`: schedule IDs are `keccak256(user, token, timestamp, length)` and are not unique, so a post-pull id check cannot substitute for the mutex. Keep period, schedule-id, amount, lending-index, access-control, malformed-calldata, underfunded-schedule, and empty-batch checks (the last two are diagnostic, not hot-path).

`depositToken` pulls before crediting. `updateDcaSchedule` keeps its memory-copy order (storage write was already after the pull) and re-validates `scheduleId` after the pull (distinct-id swap-pop only; colliding-id swap-pop there is pre-existing). See `R6-hot-path-cleanup.md`.

### PR 7 - R8 remove stuck-rBTC rescue

Delete the owner rescue path for another account's accumulated rBTC. Keep rBTC withdrawals paying `msg.sender`; do not add a `to` parameter.

### PR 8 - R1 and R20 integration cash accounting

Fix Sovryn for SIP-0094 and apply the broader rule that integrator return values and views are not cash.

Measure token/native balance deltas after Sovryn, Tropykus, MoC, and Uniswap operations that move funds to BitChill or to the user. Use views only to size share burns, then clamp to shares held.

**R6 leftover — clamp desync, this PR owns it:** `DcaManager._withdrawToken` / `deleteDcaSchedule` deduct the *requested* amount, then Tropykus/Sovryn `withdrawToken` may clamp to the user's lending position and pay less. That is not R1 (Sovryn `burn` return vs net). It is R20: do not treat the requested amount as cash paid. After the handler call, measure the user's token delta (or take the actual payout) and only deduct that from `tokenBalance`. Do not leave this as a footnote on R1.

### PR 9 - R15 withdraw-all sentinel and share dust

Add `type(uint256).max` as "withdraw this schedule's full tokenBalance." Sweep leftover lending shares when the user's locked balance for that token/protocol is zero.

This should follow R1/R20 so net redemption behavior is settled first.

### PR 10 - R22 repo layout preparation

Move protocol-specific sources and tests into folders:

- `src/sovryn/`
- `src/layerbank/`
- `src/idle/`
- `src/tropykus-legacy/`

Keep behavior unchanged where possible. Tropykus remains legacy code and tests, but it must not be registered in the new deployment path.

### PR 11 - R22 idle handler

Ship the index-0 idle DOC + MoC handler. Deposits stay on the handler; no lending token is minted; buys and withdrawals spend idle DOC.

Interest calls for index 0 should continue to revert because no protocol name is registered for index 0.

### PR 12 - R22 LayerBank handler

Add LayerBank as index 1 for DOC + MoC. Use balance-delta accounting from the start. Add mocks or fork tests based on the Rootstock LayerBank lToken ABI.

Do not rename Tropykus in place and do not deploy USDRIF/Uniswap handlers for this relaunch.

### PR 13 - R22 deploy scripts, constants, harness, and CI matrix

Update constants and deploy scripts for the new map:

- `0`: idle
- `1`: LayerBank
- `2`: Sovryn
- `3`: reserved for future MoC lending

Split the shared test harness so lending-token assertions live only in lending-protocol-specific tests. CI should cover `none`, `layerbank`, and `sovryn` with `SWAP_TYPE=mocSwaps`.

### PR 14 - R9 event indexing and ABI cleanup

Index only addresses and `scheduleId`. Do not index amounts, timestamps, periods, rates, strings, bytes, or arrays.

Do this once the shipped ABI surface is known, including any optional pause or compound-interest events that were approved.

### PR 15 - R16 redeem glossary

Rename first-party internals, events, variables, and comments so "redeem" names the token being given up. Do not rename third-party ABI functions.

This should land before the full natspec pass.

### PR 16 - R10 natspec and comments

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
