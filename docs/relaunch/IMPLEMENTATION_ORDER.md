# Relaunch implementation order

Status: **planning guide**. This file orders the relaunch work. It is not an implementation spec.

Agents should use this file to choose the next PR, then work only from the assigned `docs/relaunch/R<n>-<short-slug>.md` spec for that PR. Do not implement directly from `.cursor/relaunch-plan.md`.

## Ground rules

- One PR should have one behavioral purpose. If two R-items share the same files and tests, bundle them only when this file says so.
- Write or assign the specific `R<n>-...md` spec before implementation starts.
- Run targeted tests first, then the repo done-gate from `AGENTS.md`.
- Do not deploy, broadcast, or touch live contracts from implementation PRs.
- Keep OpenZeppelin at `v4.9.3` during the main relaunch work. A major OpenZeppelin upgrade is optional late work.

## Required decisions before code changes

Decide these before the first PR that changes fee logic, `DcaDetails`, handler per-user storage, or event ABI:

- Fee model: keep the linear decreasing fee, flatten to one rate, or leave as-is for now.
- R18 packing: skip, `DcaDetails` only, or `DcaDetails` plus handler per-user state.
- R19 pause: ship per-schedule pause in this relaunch or defer it.
- Optional items: R12 compound interest, R13 admin model, handler owner sweep, on-chain deposit pause.

Default if undecided:

- Keep OpenZeppelin `v4.9.3`.
- Skip storage packing, but still use `calldata` for handler batch arrays when those files are touched.
- Defer R12, R13, R19, owner sweep, and on-chain deposit pause.

## PR order

### PR 1 - R23 toolchain and dependency baseline

Bump first-party Solidity and Rootstock EVM settings before other code changes. Prefer the latest stable `0.8.x` compiler and `evm_version = "cancun"` if Rootstock testnet/fork verification passes.

Keep OpenZeppelin `v4.9.3`. Uniswap **sources** stay `=0.7.6` in git; they cannot be compiled with solc 0.7.6 while first-party Dex files import them (see R23). `make patch-deps` remains required. Do not include OpenZeppelin 5.x migration in this PR.

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

Trim only gas-only purchase reverts while keeping period, schedule-id, amount, lending-index, access-control, and malformed-calldata checks.

Remove unnecessary `nonReentrant` modifiers from non-rBTC-withdraw paths and make `depositToken` / `updateDcaSchedule` pull before crediting.

### PR 7 - R8 remove stuck-rBTC rescue

Delete the owner rescue path for another account's accumulated rBTC. Keep rBTC withdrawals paying `msg.sender`; do not add a `to` parameter.

### PR 8 - R1 and R20 integration cash accounting

Fix Sovryn for SIP-0094 and apply the broader rule that integrator return values and views are not cash.

Measure token/native balance deltas after Sovryn, Tropykus, MoC, and Uniswap operations that move funds to BitChill or to the user. Use views only to size share burns, then clamp to shares held.

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
