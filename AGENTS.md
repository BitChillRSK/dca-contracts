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
DcaManager          user + swapper entry; schedules
SwapperBatcher      allowlisted swapper; one tx forwards several batchBuyRbtc groups (holds no funds)
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
  src/idle/              IdleErc20Handler ── IdleDocHandlerMoc (+ PurchaseMoc)  index 0
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
4. **Index addresses and `scheduleId` only** — do not index amounts, timestamps, strings, bytes, or arrays.
5. **No assembly in purchase paths** — `batchBuyRbtc`, `_rBtcPurchaseChecksEffects`, fee loops — unless the spec authorizes it.
6. **Every external function that writes `s_dcaSchedules` carries `nonReentrant`** — the only exceptions are views and the swapper-only purchase path (`batchBuyRbtc`), which is CEI-clean and writes nothing after its handler call. Checkable with grep, deliberately not a per-function judgement call. OZ's guard only blocks *other guarded* functions, so a partial set protects nothing: a mutator left unguarded is both an unblocked re-entry point and an entry point that engages no lock. Do not narrow this set for gas — the measured saving is ~2,300 gas on user-paid transactions (~1.4 cents), and the protocol-side win lives entirely on the purchase path, which this invariant does not touch. See `docs/relaunch/R6-hot-path-cleanup.md`.
7. **The public `scheduleId` is the creation nonce (`uint64`), never a hash and never array state** — `createDcaSchedule` pre-increments `s_protocolSettings.scheduleNonce` and stores that value as the schedule's id, so ids start at 1 and `getSchedulesCreatedCount()` is the last one assigned. `deleteDcaSchedule` swap-pops, which can restore a previous array shape inside one block, so any id derived from array contents (length, last element's id, a hash of the array) can be reminted while the original schedule is still live. Only a strictly increasing counter is safe. R50 removed the `keccak256(user, token, nonce)` wrapper: it added a word per schedule and hid nothing, since ids are public through `getDcaSchedules` and are stale-index checks, not capabilities.

## Onchain comments

Verified `src/` source (including NatSpec) lives on explorers for the life of the deployment. Do not mention relaunch ticket IDs (`R29`, `R42`, …) in `src/` comments. Write the durable reason instead. Specs, tests, PRs, deploy-script comments, and this file may use R-ids.

## Tests and done-gate

- Targeted tests for the spec first. Document exact commands in the PR.
- **Done-gate:** `make check` (`forge build`, `make moc-none`, `make moc-layerbank`, `make moc-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-layerbank`, `STABLECOIN_TYPE=USDT0 make dex-layerbank`, and `make invariants-sovryn`).
- **Before push (every relaunch PR):** `make check` is not enough. Also run `make fork-sovryn` and `make fork-tropykus` (need `RSK_MAINNET_RPC_URL` in `.env`). Fork tests are not in CI; Anvil lanes will not catch live-protocol mismatches (for example R1's batch event reports net DOC, while `makeBatchPurchasesOneUser` used to expect the requested gross). If the RPC is unset, stop and ask the human — do not push. Document the exact fork commands in the PR.
- **CI (every PR):** `make moc-none`, `make moc-layerbank`, `make moc-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-layerbank`, `STABLECOIN_TYPE=USDT0 make dex-layerbank`, and `make invariants-sovryn`. Locally, `make ci` runs those lanes under `FOUNDRY_PROFILE=ci`. The unit lanes still `--no-match-test invariant` so the 64×512 stateful suite is not multiplied across every target. `ComparePurchaseMethods` stays excluded (Anvil early-return / mainnet-only). Local Tropykus targets (`make moc-tropykus` / `make dex-tropykus`) remain useful for mock-based coverage of the legacy handler through a second lending adapter; Tropykus is on neither production map, and index 4 stays burned. Tropykus fork tests pin a pre-pause block; see the fork-tests bullet below.
- Defaults: `SWAP_TYPE=mocSwaps`, `LENDING_PROTOCOL=tropykus` (legacy local default), `STABLECOIN_TYPE=DOC`. Production MoC lanes are `none` / `layerbank` / `sovryn`. Dex paths often use `STABLECOIN_TYPE=USDRIF`.
- `make patch-deps` applies the vendored Uniswap pragma compatibility patch used by local builds and CI. It mutates `lib/` submodules; do not commit those submodule dirties.
- `make slither` if slither is installed; not part of `make check` (no clean baseline yet).
- Do not `forge fmt` existing files unless the spec says to (`src/` is not fmt-clean).
- Fork tests (`make fork-*`) need an RPC and are not in CI. `test/mainnet-debug/**` is excluded from normal local/CI runs. They run on **Anvil/revm**, not rskj: useful for live Sovryn/MoC state, **not** a Rootstock opcode/compiler proof. `make fork-*` passes `SWAP_TYPE` (default `mocSwaps`) and sources `.env` for `RSK_MAINNET_RPC_URL` — an empty `--fork-url` makes Forge treat the cwd as an IPC socket. `make fork-tropykus` (and `make fork` when `LENDING_PROTOCOL=tropykus`) pins `--fork-block-number 8700000` (2026-04-05), before Tropykus paused kDOC mint. The pause is between blocks 8739512 and 8740674 (2026-04-16/17), measured by bisecting mint on a fork; above it, deposits revert with kToken error `C2`. `make fork-sovryn` stays on the chain tip. Do not `vm.setEnv("LENDING_PROTOCOL", …)` in tests — it is process-wide and makes every later suite ignore the Makefile lane (`EXPECTED_LENDING_PROTOCOL` is the canary).

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
