# AGENTS.md

Foundry Solidity repo for BitChill DCA-in contracts on Rootstock (`0.8.36`, EVM `cancun`). Users talk to `DcaManager`; a swapper bot triggers purchases; handlers hold funds and talk to lending, Money on Chain, and Uniswap.

## Read order

1. This file.
2. `docs/relaunch/IMPLEMENTATION_ORDER.md` when choosing the next relaunch PR or checking dependency gates.
3. The assigned spec under `docs/relaunch/` (required before Solidity changes).
4. Start from the spec’s file list. Expand only through imports, inheritance, interfaces, mocks, failing tests, and compiler errors. Name extra files in the PR. If a later commit adds or re-purposes a path, update the open PR body in the same turn — the first description is not a one-shot.

Do not implement optional/further-review items unless the spec assigns them. Sibling repo `dca-out-contracts` is out of scope unless named.

## Starting a relaunch chat

The human prompt is one line: `Start with R2` or `Start with PR 3`. Do not expect base branch, fee model, or “don’t start the next item” in the prompt.

1. Map the R-item to a PR in `IMPLEMENTATION_ORDER.md`. One chat = that PR only. Stop when the PR is open and README Status is updated. Remind the human of the next unassigned prompt.
2. If `docs/relaunch/R<n>-*.md` is missing, copy `TASK_TEMPLATE.md`, fill it, and assign it in `docs/relaunch/README.md` **before** Solidity. You may read gitignored `.cursor/relaunch-plan.md` **only** to draft that one spec. Implement from the spec, never from the plan.
3. Ask the human **only** the open product gates listed for that PR in `IMPLEMENTATION_ORDER.md` (and the spec’s **Open product decisions** section). If that list is empty, do not ask; implement. Do not ask fee / packing / pause / optional items unless that PR’s list names them.
4. `git fetch`. Branch from `main` if no relaunch PR is open; otherwise from the latest open relaunch PR’s head (stack). Never implement on `main`. Branch **before** the first edit.

## Layout

Do not Grep/`Glob` `out/`, `cache/`, or `lib/` (see `.cursorignore`). Open a `lib/` path only when a `src/` import points there.

```
DcaManager          user + swapper entry; schedules; single- and multi-handler purchases
OperationsAdmin     roles; token × lending-index → handler
FeeHandler          fee math (inherited by TokenHandler and PurchaseRbtc)
TokenHandler        deposit/withdraw stablecoin (owns FeeHandler)
TokenLending        share ↔ underlying conversion (no TokenHandler inherit)
LendingErc20Handler TokenHandler + TokenLending; per-user shares, withdraw clamp, interest, batch pro-rata
StablecoinSource    funding-hook + _purchaseToken declarations (PurchaseRbtc consumes; lending/idle implement)
PurchaseRbtc        shared buy/batch pipeline; accumulated rBTC; withdraw to signer
PurchaseMoc         MoC redeem DOC → rBTC (_purchaseRbtc only)
PurchaseUniswap     Uniswap V3 → WRBTC (_purchaseRbtc + WRBTC unwrap on withdraw)

Handlers = LendingErc20Handler + a Purchase*  (lending adapters) or TokenHandler + a Purchase* (idle):
  src/idle/              IdleErc20Handler ─┬─ IdleDocHandlerMoc (+ PurchaseMoc)  index 0 (DOC)
                                          └─ IdleErc20HandlerDex (+ PurchaseUniswap)  index 0 (USDRIF / USDT0)
  src/layerbank/         LayerBankErc20Handler ─┬─ LayerBankDocHandlerMoc (+ PurchaseMoc) index 1
                                               └─ LayerBankErc20HandlerDex (+ PurchaseUniswap)  USDRIF / USDT0
  src/sovryn/            SovrynErc20Handler ─┬─ SovrynDocHandlerMoc   (+ PurchaseMoc)  index 2
                                            └─ SovrynErc20HandlerDex (+ PurchaseUniswap)
  src/tropykus-legacy/   TropykusErc20Handler ─┬─ TropykusDocHandlerMoc   (+ PurchaseMoc)
                                              └─ TropykusErc20HandlerDex (+ PurchaseUniswap)
                             test-only: no live deploy branch builds one, on either map
```

- `src/interfaces/` — shared first-party ABIs; keep in sync with implementations. Protocol-specific interfaces (`IiSusdToken`, `IkToken`, `IIdleErc20Handler`, `ILayerBankAToken`, `ILayerBankPool`, `ILayerBankErc20Handler`) live next to their handlers. Lending handlers share `ITokenLending` directly — R16 removed the empty per-protocol lending interfaces, so do not add one for a new handler unless it actually declares something (errors, events, or protocol-specific views — same bar as Idle).
- `test/unit/DcaDappTest.t.sol` — shared harness; **requires** `SWAP_TYPE` and `LENDING_PROTOCOL` (no fallback).
- `test/unit/`, `test/mocks/`, `test/ai-generated/` — unit / mocks / extra + fuzz. Dedicated handler tests: `test/ai-generated/unit/sovryn/`, `test/ai-generated/unit/tropykus-legacy/`, `test/ai-generated/unit/idle/`, `test/ai-generated/unit/layerbank/`.
- `script/` — deploy helpers. Do not `--broadcast` or talk to live contracts. `TROPYKUS_INDEX` deliberately lives in `test/Constants.sol`, not `script/Constants.sol`, so a `script/` file that names a Tropykus route does not compile; `TROPYKUS_STRING` stays in `script/Constants.sol` because the helper configs select mocks with it. Do not move the index back or re-add a Tropykus arm to a live branch — both live branches reject `Protocol.TROPYKUS`. A new production handler ships its deploy path in the same PR: extend `DeployMocSwaps` / `DeployDexSwaps` when it belongs in the main index map, or add a `Deploy<Handler>.s.sol` add-on (see `DeployUsdrifHandler`, `DeployIdleHandler`, `DeployLayerBankHandler`). DcaManager and deployment tests must construct that handler through the script (`DcaDappTest`, `BaseDeploymentTest`, `NewHandlerDeploymentTest`). `new Handler(...)` is only for test subclasses that expose internals, or handler-level tests that set `dcaManager` to the test contract so they can call `onlyDcaManager` entry points.

## Protocol invariants

Unless the assigned spec explicitly changes one:

1. **Balance-delta cash** — after a call that should move tokens or native to us, measure `balanceOf` / `address(this).balance` (or the user’s balance when paying the user). Do not treat integrator return values as received funds.
2. **No view as redeem ceiling** — do not cap redemptions with `assetBalanceOf`, `profitOf`, snapshots, or `tokenPrice` as “DOC we will get.” Rates may size share burns, then clamp to shares held.
3. **rBTC pays the signer** — withdrawals go to `msg.sender`. No `to` parameter; no owner rescue of another account’s rBTC.
4. **Index every scalar address and `scheduleId`, and nothing else** — do not index amounts, timestamps, strings, bytes, arrays, or address arrays / bytes paths.
5. **No assembly in purchase paths** — `batchBuyRbtc`, `_rBtcPurchaseChecksEffects`, fee loops — unless the spec authorizes it.
6. **Every external function that writes `s_dcaSchedules` carries `nonReentrant`, views excepted — including both swapper purchase paths.** R66 removed the exception the purchase paths used to hold: a batch cannot know which rows its handler could fund until the handler returns, so `_batchBuyRbtc` checks every row, calls the handler once, and only then debits the rows that funded. Those writes follow an external call, and the guard is what keeps an owner mutation or a second purchase out of that window. Do not take it off while any schedule write follows a handler interaction. It costs 5,207 gas a batch, on a swapper-paid transaction — measured, and the price of the guarantee. Checkable with grep, deliberately not a per-function judgement call. OZ's guard only blocks *other guarded* functions, so a partial set protects nothing: a mutator left unguarded is both an unblocked re-entry point and an entry point that engages no lock. Do not narrow this set for gas — the measured saving is ~2,300 gas on user-paid transactions (~1.4 cents). See `docs/relaunch/R66-batch-row-front-running.md`, `docs/relaunch/R6-hot-path-cleanup.md` and `docs/relaunch/R42-swapper-batcher.md`.
7. **The public `scheduleId` is the creation nonce (`uint64`), never a hash and never array state** — `createDcaSchedule` pre-increments `s_protocolSettings.scheduleNonce` and stores that value as the schedule's id, so ids start at 1 and `getSchedulesCreatedCount()` is the last one assigned. `deleteDcaSchedule` swap-pops, which can restore a previous array shape inside one block, so any id derived from array contents (length, last element's id, a hash of the array) can be reminted while the original schedule is still live. Only a strictly increasing counter is safe. R50 removed the `keccak256(user, token, nonce)` wrapper: it added a word per schedule and hid nothing, since ids are public through `getDcaSchedules` and are stale-index checks, not capabilities.

8. **A schedule is keyed by `(token, scheduleId)`, and the stored owner is checked in exactly one place** — `s_dcaSchedules` is `mapping(address token => mapping(uint64 scheduleId => DcaSchedule))`. The stablecoin is keyed first because that is how the work arrives: a batch is one handler's, so one stablecoin's, and its rows carry ids rather than repeating the token. Reach a schedule through `_callersSchedule(token, scheduleId)`, which is the only ownership check in the contract: it refuses a pair that addresses nothing (`InexistentSchedule`) and then refuses a schedule whose stored `user` is not `msg.sender` (`NotScheduleOwner`). Do not add a second owner check anywhere, and never accept a `user` argument on a schedule mutator — a caller-supplied owner is not a check. A reviewer's obligation is one grep: no mutator may read `s_dcaSchedules` directly. The `onlySwapper` purchase path needs no ownership check at all, because it takes the buyer from the schedule rather than from the batch; the stablecoin it names is structural, so a row of another one addresses empty storage and is refused rather than debited by a handler that never held its funds. Every getter is free to read any schedule. `DcaSchedule` is two slots and holds neither half of its key: slot 0 is every field a purchase touches, slot 1 pairs the owner with a `uint96 purchaseAmount`. There is no second, storage-only schedule type — `getDcaSchedules` returns the ids in a parallel array instead of repeating them inside the value. `s_scheduleIds[user][token]` is enumeration only: `getDcaSchedules` and the max-schedules bound read it, and no purchase ever does. See `docs/relaunch/R64-batch-calldata-and-schedule-keying.md`.

9. **A batch row is one packed `bytes32`: an id plus the amount the swapper quoted, and nothing else** — `Batch` is `bytes32[] rows` (high 64 bits the `scheduleId`, low 96 bits the `expectedPurchaseAmount`, top 96 bits zero), plus the `token` and `routeIndex` that resolve to one handler and the batch's `minRbtcOutRate`. `_batchBuyRbtc` still reads both the buyer and the amount it actually spends from each schedule. Do not add a per-row buyer back: the owner comes from storage, which is what lets a row stay one word, and a caller-supplied owner would be trusted input on the one path that reaches somebody else's schedule. The packed `expectedPurchaseAmount` is **not** a substitute for the stored amount — it is only compared against it, and a row that no longer matches is skipped rather than purchased at a size the swapper never quoted. R64 had removed that comparison; R66 restored it in packed form after review found that without it, an owner raising their `purchaseAmount` between the swapper's query and its transaction could push the batch's aggregate input through a pool's depth. A `uint64[]` element already occupied a full ABI word, so the packing costs only the zero→non-zero calldata bytes.

   **One row's owner must never cost another row its purchase — through either book.** Every condition a schedule's own owner can flip between the swapper's snapshot and the tick landing is a **skip**, reported as `DcaManager__PurchaseRowSkipped(token, scheduleId, reason)`. Five of them are read off the schedule by `_rBtcPurchaseChecks`, which returns a zero amount and writes nothing: deleted, paused, not yet due, short of balance, or a stale `expectedPurchaseAmount`. The sixth, `FundingInsufficient`, is the handler's answer and cannot be anything else: a schedule's principal and the funds behind it are two different books, the second is pooled across that buyer's schedules on the route, and a lending handler's rounding can leave a tail schedule wanting one share more than its owner holds. R43 kept that as a batch revert on the assumption that the bot filters the tail; R66 supersedes it, because the owner reaches that state *after* the bot's snapshot with every field the manager checks untouched. Skipping never clamps, forgives or subsidises a shortfall — a short row would still carry its full weight through the allocation and so be paid for out of the other buyers' stablecoin.

   That is why `_batchBuyRbtc` checks every row, calls the handler once, and debits only afterwards: handlers filter unfundable rows in place before charging any fee or buying anything, and return `unfundedRows`, the ascending indexes they dropped (empty in the usual case). Nothing is written before that call — an optimistic debit would have to be taken back, and a dropped row would have consumed a period it never bought in. Two rules pay for it and must not be quietly dropped: both purchase entries carry `nonReentrant` (invariant 6), and a batch's rows must be in **strictly increasing schedule-id order**, skipped rows included, or `DcaManager__BatchRowsNotSorted`. Without the sort, the same schedule listed twice would pass the checks twice and buy twice; one comparison a row makes that unrepresentable. A batch whose rows all skip calls no handler and does not revert, and neither does one whose every remaining row goes unfunded; only a literally empty `rows` array is malformed input (`DcaManager__EmptyBatchPurchaseArrays`). Do not turn any owner-controlled condition back into a revert, and do not add a new purchase-path check that reverts on state an owner controls. The `routeIndex` comparison and the sort rule are the deliberate exceptions and stay hard reverts: neither is anything an owner can cause.

   **`minRbtcOutRate` is a rate, applied to measured spend.** It is rBTC/WRBTC wei per raw stablecoin wei, 1e18-scaled — not an absolute rBTC figure. `PurchaseRbtc.batchBuyRbtc` computes `requiredMinimum = mulDiv(rate, totalStablecoinAmountToSpend, 1e18, Ceil)` against the stablecoin it measured itself spending on this tick, and compares that to the rBTC it measured itself receiving, so the bound stays meaningful when the amount actually spent differs from the one quoted. Do not reintroduce an absolute minimum, and do not apply the rate to a planned or pre-fee figure. Every route enforces it, MoC included: MoC has no *oracle* floor of its own (DOC is redeemed at Money on Chain's price rather than swapped against a pool), but it is not exempt from the caller's floor, which the shared pipeline applies above both routes. A Uniswap route additionally derives its swap-time `amountOutMinimum` from the same rate against the same actual input and composes with its oracle floor as `max(...)`, so the caller can only tighten. See `docs/relaunch/R66-batch-row-front-running.md`.

## Section headers and function order

First-party `src/` files use Foundry-style banners with these exact titles. When a section is non-empty, emit its banner; skip empty ones. Order:

`TYPE DECLARATIONS` → `STATE VARIABLES` → `EVENTS` → `ERRORS` → `MODIFIERS` → `CONSTRUCTOR` → `EXTERNAL FUNCTIONS` → `GETTERS` → `INTERNAL FUNCTIONS` → `PRIVATE FUNCTIONS`.

- **Floor:** constructor-only contracts (the only declaration is `constructor`) carry no banners — that is the leaf-handler shape (`IdleDocHandlerMoc`, `*Erc20HandlerDex`, `*DocHandlerMoc`, …). Every other first-party file uses banners for each non-empty section.
- **Visibility:** external → public → internal → private. The externally reachable surface is therefore always the top of the file, which is what makes it readable in one pass; that property, not the banners, is the point of the ordering.
- **EXTERNAL FUNCTIONS** holds `external` / `public` entry points that write state, including `receive` / `fallback` and `public` overrides. It is decided by mutability, not by name: `getAccruedInterest` is deliberately non-`view` and belongs here.
- **GETTERS** holds `view` / `pure` `external` / `public` accessors — reads a caller makes for an answer. `supportsInterface` (the public view ERC-165 override) lives here. A `view` / `pure` function that only reverts is a disabled mutator, not an accessor, and stays with the mutators (`BitChillOwnable.renounceOwnership`).
- Mutators before views applies **within EXTERNAL FUNCTIONS / GETTERS only** — that split is the whole of the rule. Internal and private helpers are ordered by call order, closest caller first, because grouping them by mutability separates a function from the helper it calls for no reader's benefit.
- Interfaces follow the same split as their implementation, in the same declaration order, so a reader can diff the pair. `IWRBTC` and the other vendored files below are the exception.
- Each banner title uses one indentation everywhere: `GETTERS` at column 32, `EXTERNAL FUNCTIONS` at 27. When renaming a banner, re-centre it rather than leaving the old padding.
- Do not use `FUNCTIONS`, `GETTER FUNCTIONS`, or other spellings.
- Leave vendored interfaces alone so they stay diffable against upstream: `IMocProxy`, `IWRBTC`, `ICoinPairPrice`, `IkToken`, `IiSusdToken`, `ILayerBankPool`, `ILayerBankAToken`.

## Contract header NatSpec

Solidity inherits NatSpec for functions, events, errors, and public state variables, so the function
layer is written once, on the interface, and reaches the implementation through `@inheritdoc`. It does
**not** inherit the `@title`/`@notice`/`@dev` block above a contract, and `@inheritdoc` is not an escape
hatch: on a contract it fails the compile outright (`Error (6546): Documentation tag @inheritdoc not
valid for contracts`). Header NatSpec is own-file — it does not cross `is` to an implementation, and it
does not travel down an inheritance chain either, so `SovrynDocHandlerMoc` inherits nothing from
`SovrynErc20Handler`'s header. The header layer is therefore written by hand, and this is where.

**A deployed contract must be readable on its own.** Anyone auditing this protocol lands on the verified
concrete contract. Every contract that is actually deployed — `DcaManager`, `OperationsAdmin`, and the
handler leaves — carries a short `@dev` covering its own security and lifecycle model: what is
irreversible, what is guarded, what can be paused, who may call. Write it even when the interface says
the same thing. That overlap is deliberate redundancy on the artifact that ships, not duplication to be
factored out, and it is the one place where restating the interface is correct.

Everything else is single-sourced on the interface:

- Every first-party `src/` file carries `@title`, `@author`, and exactly one `@notice` line.
- The two `@notice` lines of an interface/implementation pair are labels, and must not be the same
  sentence. The interface's names the surface; the implementation's names what that contract is in the
  system. A one-line label on each side is not duplication.
- The full paragraph — the caller-facing rules and the reasoning behind them — belongs to the interface
  that declares the functions it describes. An **abstract** contract adds a `@dev` only for a fact about
  its own code that a reader of the surface could not infer; an abstract's header reaches no shipped
  artifact whichever side it sits on, so there is nothing to be gained by restating the interface there.
- Two cases where no interface owns the claim, so it stays on the implementation. An interface that
  declares no functions (`IDcaManagerAccessControl`, `IPurchaseMoc`, `ILayerBankErc20Handler`) is a home
  for errors and events, not a surface: its `@notice` says what it carries. And a fact true of one
  implementation cannot live on an interface several share — `ITokenLending` is Sovryn's, LayerBank's,
  and Tropykus's at once.
- Constructor-only leaves carry the header even though they carry no banners, and sibling leaves state
  the same fact the same way: the four `*Erc20HandlerDex` contracts each say `Constructor-only leaf` and
  the funding-base-first constructor ordering in `@dev`, not one of them in `@notice`.

**Do not name a token in a contract that does not name it itself.** `PurchaseUniswap`, `IdleErc20Handler`,
`LendingErc20Handler`, `TokenHandler` and their interfaces are constructed with whatever stablecoin they
are given; a comment listing DOC, USDRIF, or USDT0 there is a snapshot of a listing decision that will
rot, and on the Uniswap path naming DOC is simply wrong — DOC is redeemed at MoC and never swapped.
State the property the code relies on (a decimal bound, a peg assumption) instead of the roster that
happens to satisfy it today. Token names are correct only where the contract is token-specific: the
`*DocHandlerMoc` leaves, `PurchaseMoc`, and the per-protocol `README.md`s.

**Say what is enforced, and what is only assumed.** A header that states an operational policy the
contract does not check — a listing rule, a delisting process — reads as a safety mechanism and is not
one. Name it as a precondition and say who owns it.

## Onchain comments

Verified `src/` source (including NatSpec) lives on explorers for the life of the deployment. Do not mention relaunch ticket IDs (`R29`, `R42`, …) in `src/` comments. Write the durable reason instead. Specs, tests, PRs, deploy-script comments, and this file may use R-ids.

## Tests and done-gate

- Targeted tests for the spec first. Document exact commands in the PR.
- **Done-gate:** `make check` (`forge build`, `make moc-none`, `make moc-layerbank`, `make moc-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-none`, `STABLECOIN_TYPE=USDT0 make dex-none`, `STABLECOIN_TYPE=USDRIF make dex-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-layerbank`, `STABLECOIN_TYPE=USDT0 make dex-layerbank`, and `make invariants-sovryn`).
- **Before push (every relaunch PR):** `make check` is not enough. Also run `make fork-sovryn` and `make fork-tropykus` (need `RSK_MAINNET_RPC_URL` in `.env`). Fork tests are not in CI; Anvil lanes will not catch live-protocol mismatches (for example R1's batch event reports net DOC, while `makeBatchPurchasesOneUser` used to expect the requested gross). If the RPC is unset, stop and ask the human — do not push. Document the exact fork commands in the PR.
- **CI (every PR):** `make moc-none`, `make moc-layerbank`, `make moc-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-none`, `STABLECOIN_TYPE=USDT0 make dex-none`, `STABLECOIN_TYPE=USDRIF make dex-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-layerbank`, `STABLECOIN_TYPE=USDT0 make dex-layerbank`, and `make invariants-sovryn`. Locally, `make ci` runs those lanes under `FOUNDRY_PROFILE=ci`. The unit lanes still `--no-match-test invariant` so the 64×512 stateful suite is not multiplied across every target. `ComparePurchaseMethods` stays excluded (Anvil early-return / mainnet-only). Local Tropykus targets (`make moc-tropykus` / `make dex-tropykus`) remain useful for mock-based coverage of the legacy handler through a second lending adapter; Tropykus is on neither production map, and index 4 stays burned. Tropykus fork tests pin a pre-pause block; see the fork-tests bullet below.
- Defaults: `SWAP_TYPE=mocSwaps`, `LENDING_PROTOCOL=tropykus` (legacy local default), `STABLECOIN_TYPE=DOC`. Production MoC lanes are `none` / `layerbank` / `sovryn`. Dex paths often use `STABLECOIN_TYPE=USDRIF` (idle+DEX and LayerBank).
- `make patch-deps` applies the vendored Uniswap pragma compatibility patch used by local builds and CI. It mutates `lib/` submodules; do not commit those submodule dirties.
- `make slither` if slither is installed; not part of `make check` (no clean baseline yet).
- Do not `forge fmt` existing files unless the spec says to (`src/` is not fmt-clean).
- Fork tests (`make fork-*`) need an RPC and are not in CI. `test/mainnet-debug/**` is excluded from normal local/CI runs. They run on **Anvil/revm**, not rskj: useful for live Sovryn/MoC state, **not** a Rootstock opcode/compiler proof. `make fork-*` passes `SWAP_TYPE` (default `mocSwaps`) and sources `.env` for `RSK_MAINNET_RPC_URL` — an empty `--fork-url` makes Forge treat the cwd as an IPC socket. `make fork-tropykus` (and `make fork` when `LENDING_PROTOCOL=tropykus`) pins `--fork-block-number 8700000` (2026-04-05), before Tropykus paused kDOC mint. The pause is between blocks 8739512 and 8740674 (2026-04-16/17), measured by bisecting mint on a fork; above it, deposits revert with kToken error `C2`. `make fork-sovryn`, `make fork-layerbank`, and `make fork-none` stay on the chain tip. Dex path allowlist coverage on a fork is `make fork-dex-path` (`DexPathFailoverTest` on USDRIF / LayerBank **and** USDRIF / idle / dexSwaps). Constructor self-allowlists the initial Dex path; do not require a separate `setPurchasePathAllowed` before `assignTokenHandler`. Full live-Uniswap purchase coverage for Dex leaves is `SWAP_TYPE=dexSwaps STABLECOIN_TYPE=USDRIF make fork-layerbank` (LayerBank) and `SWAP_TYPE=dexSwaps STABLECOIN_TYPE=USDRIF make fork-none` (idle); those can still revert `Too little received` and are not the R52 gate. Do not `vm.setEnv("LENDING_PROTOCOL", …)` in tests — it is process-wide and makes every later suite ignore the Makefile lane (`EXPECTED_LENDING_PROTOCOL` is the canary).

## Git (relaunch)

Do this even if a user-level rule says “don’t commit until asked.” An assigned `docs/relaunch/` spec **is** authorization to branch, commit, push, and open a PR.

1. **Branch before the first edit** (`git checkout -b <type>/r<n>-<slug>` from the base in **Starting a relaunch chat**).
2. **Commit when the spec’s success criteria pass.** Small, targeted commits (spec/docs, then code, then follow-up docs). Subject: `type: why`.
3. **Push and open a PR** only after `make check`, `make fork-sovryn`, and `make fork-tropykus` pass. Use `.github/PULL_REQUEST_TEMPLATE.md`. Point at the spec. Do not commit `lib/` dirt from `make patch-deps`, secrets, or `.env`.
4. **One implementer per PR.** Parallel review (Cursor/Codex/Claude/Bugbot) is expected. Parallel implementation on overlapping Solidity is not. Skip git worktrees for this relaunch except a docs-only PR that does not share files.
5. After the PR is open, set `docs/relaunch/README.md` **Status** to this PR (full GitHub link) and “next unassigned: …” (the one-line prompt for the following chat). If the URL is only known after opening, add that Status update in a follow-up commit and push, then stop. Do not start the next R-item in this chat. The human merges in order. In the closing message, remind the human of that next prompt so they can spin up the following agent.
6. **Keep the PR body current.** After any review or audit follow-up that changes the diff, edit the GitHub description in the same turn (`gh pr edit`) before you stop. **Files beyond the spec** must name every path in `gh pr diff --name-only` that the spec’s file list does not, with a one-line why. Update an existing entry when its reason changed (checkbox flips vs a new out-of-scope bullet). Do not leave the body describing only the first push.
7. **Consumer follow-up** (see below): if this PR changes anything a consumer repo reads, sends, or indexes, open or update an issue on each affected repo in the same turn and paste the URLs in the PR **Cutover / frontend note**.

## PRs

Small, behavior-scoped, reviewable history. No drive-by refactors. Use the template. Do not restate the invariants — say whether they still hold. After review follow-ups, refresh the body so **Files beyond the spec** matches the current diff.

When reviewing a PR by number, fetch its actual diff (e.g. `gh pr diff <N>` or `gh pr view <N> --json files`) and confirm the changed files match before trusting any findings — don't assume the locally checked-out branch is that PR's diff.

## Consumer follow-up

The contracts have five sibling consumers. Do not implement consumer changes in this repo — open an issue there.

| Repo | Consumes | Owns |
|---|---|---|
| [`front-end`](https://github.com/BitChillRSK/front-end) | `DcaManager` user surface | user calls, hardcoded ABIs, route indexes, venue names |
| [`swapper-bot`](https://github.com/BitChillRSK/swapper-bot) | `batchBuyRbtc`, swapper allowlist | tick composition, gas splitting, per-handler cron targets |
| [`bitchill-monitoring`](https://github.com/BitChillRSK/bitchill-monitoring) | events and custom errors | alerting, backfill, `abi.json` |
| [`data-api`](https://github.com/BitChillRSK/data-api) | schedule and purchase state | the schedule model the bot and dashboard read |
| [`metrics-dashboard`](https://github.com/BitChillRSK/metrics-dashboard) | `data-api` output, venue labels | reporting, venue naming |

When a contracts PR changes anything a consumer must handle after relaunch, **search that repo's existing issues first**, then **open a new issue or comment on the matching one** in the same turn as opening or updating the contracts PR. Paste every issue URL in the contracts PR **Cutover / frontend note**. Do not wait for merge.

```
gh issue list --repo BitChillRSK/<repo> --state all --limit 50
gh issue create --repo BitChillRSK/<repo> --title "…" --body "…"
```

`data-api` sits upstream of both `swapper-bot` and `metrics-dashboard`. A change to the schedule model usually needs an issue on `data-api` **and** on each downstream repo — do not assume the API change propagates on its own.

**Open or update an issue when the PR:**

- **front-end** — adds, removes, or changes a public selector, argument list, event, or custom error on `DcaManager`, `OperationsAdmin`, or any contract the UI calls (handlers, fee reads, purchase-rBTC getters); accepts a new argument value the UI cannot send (for example `type(uint256).max` as withdraw-all); adds or remaps a route index or venue; or breaks a behavior the UI assumes (caller-only `getMy*` getters, hardcoded `1 = Tropykus` / `2 = Sovryn`, interest on every index).
- **swapper-bot** — changes `batchBuyRbtc`'s selector, argument list, or grouping rules; adds state the bot must filter on before batching (a paused schedule reverts the whole batch); changes which addresses are allowlisted swappers or adds a contract the bot should call instead; changes route indexes, the live handler set, or per-handler cron targets; or changes token decimals, minimum purchase amounts, or min-out math the bot reproduces off-chain.
- **bitchill-monitoring** — adds, removes, renames, or re-indexes any event or custom error; changes the deployed handler set it watches; or changes an event's field meaning even when the signature is stable. Assume `abi.json` needs regenerating.
- **data-api** — changes the schedule struct, its field names or types, a getter it reads, or the set of tokens and routes it must serve. Storage packing counts if a field's type changes.
- **metrics-dashboard** — changes venue naming, the route index map, or any `data-api` field it renders.

**Do not open an issue for:** internal-only renames with no ABI effect, tests, Makefile, deploy scripts no consumer calls, owner-only surfaces no consumer exposes, or natspec.

The issue body should name the contracts PR, the old vs new surface (selector and args, or event and fields), the consumer files that still use the old one, and whether it is a small ABI edit or a product change (new venue, new flow). If an existing issue already covers it, comment there instead of duplicating.
