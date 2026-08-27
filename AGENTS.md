# AGENTS.md

Foundry Solidity repo for BitChill DCA-in contracts on Rootstock (`0.8.36`, EVM `cancun`). Users talk to `DcaManager`; a swapper bot triggers purchases; handlers hold funds and talk to lending, Money on Chain, and Uniswap.

## Read order

1. This file.
2. `docs/relaunch/IMPLEMENTATION_ORDER.md` when choosing the next relaunch PR or checking dependency gates.
3. The assigned spec under `docs/relaunch/` (required before Solidity changes).
4. Start from the spec’s file list. Expand only through imports, inheritance, interfaces, mocks, failing tests, and compiler errors. Name extra files in the PR.

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
OperationsAdmin     roles; token × lending-index → handler
FeeHandler          fee math (also inherited by Purchase*)
TokenHandler        deposit/withdraw stablecoin (owns FeeHandler)
TokenLending        share ↔ underlying conversion (no TokenHandler inherit)
PurchaseRbtc        accumulated rBTC; withdraw to signer
PurchaseMoc         MoC redeem DOC → rBTC
PurchaseUniswap     Uniswap V3 → WRBTC

Handlers = TokenHandler + TokenLending + a Purchase*:
  TropykusErc20Handler ─┬─ TropykusDocHandlerMoc      (+ PurchaseMoc)
                        └─ TropykusErc20HandlerDex    (+ PurchaseUniswap)
  SovrynErc20Handler   ─┬─ SovrynDocHandlerMoc        (+ PurchaseMoc)
                        └─ SovrynErc20HandlerDex      (+ PurchaseUniswap)
```

- `src/interfaces/` — first-party ABIs; keep in sync with implementations.
- `test/unit/DcaDappTest.t.sol` — shared harness; **requires** `SWAP_TYPE` and `LENDING_PROTOCOL` (no fallback).
- `test/unit/`, `test/mocks/`, `test/ai-generated/` — unit / mocks / extra + fuzz.
- `script/` — deploy helpers. Do not `--broadcast` or talk to live contracts.

## Protocol invariants

Unless the assigned spec explicitly changes one:

1. **Balance-delta cash** — after a call that should move tokens or native to us, measure `balanceOf` / `address(this).balance` (or the user’s balance when paying the user). Do not treat integrator return values as received funds.
2. **No view as redeem ceiling** — do not cap redemptions with `assetBalanceOf`, `profitOf`, snapshots, or `tokenPrice` as “DOC we will get.” Rates may size share burns, then clamp to shares held.
3. **rBTC pays the signer** — withdrawals go to `msg.sender`. No `to` parameter; no owner rescue of another account’s rBTC.
4. **Index addresses and `scheduleId` only** — do not index amounts, timestamps, strings, bytes, or arrays.
5. **No assembly in purchase paths** — `buyRbtc`, `batchBuyRbtc`, `_rBtcPurchaseChecksEffects`, fee loops — unless the spec authorizes it.

## Tests and done-gate

- Targeted tests for the spec first. Document exact commands in the PR.
- **Toolchain:** CI pins Foundry to `v1.7.1` in `.github/workflows/test.yml`. Match it locally (`foundryup -i v1.7.1`) before trusting the done-gate. Forge **1.8.0 is known-broken here**: suites that build fixtures with `vm.prank(OWNER); new OperationsAdmin();` fail at `setUp()` with `vm.prank: cannot overwrite a prank until it is applied at least once` (10 of them on the relaunch stack head; fewer on `main` today, since the stack adds more). That is a toolchain incompatibility this repo still owes a migration for, not a bug in your change — do not "fix" those tests to chase it, and do not unpin CI.
- **Done-gate:** `make check` (`forge build`, `make moc-tropykus`, `make moc-sovryn`, and `STABLECOIN_TYPE=USDRIF make dex-sovryn`).
- **CI (every PR):** `make moc-sovryn` and `STABLECOIN_TYPE=USDRIF make dex-sovryn`. Locally, `make ci` runs those lanes under `FOUNDRY_PROFILE=ci`. Local Tropykus targets remain useful for mock-based coverage; Tropykus fork deposits may fail while live mint is paused.
- Defaults: `SWAP_TYPE=mocSwaps`, `LENDING_PROTOCOL=tropykus`, `STABLECOIN_TYPE=DOC`. Dex paths often use `STABLECOIN_TYPE=USDRIF`.
- `make patch-deps` applies the vendored Uniswap pragma compatibility patch used by local builds and CI. It mutates `lib/` submodules; do not commit those submodule dirties.
- `make slither` if slither is installed; not part of `make check` (no clean baseline yet).
- Do not `forge fmt` existing files unless the spec says to (`src/` is not fmt-clean).
- Fork tests (`make fork-*`) need an RPC and are not in CI. `test/mainnet-debug/**` is excluded from normal local/CI runs. They run on **Anvil/revm**, not rskj: useful for live Sovryn/MoC state, **not** a Rootstock opcode/compiler proof. `make fork-*` currently passes `--no-match-path` twice (Forge rejects that); use one glob until that Makefile bug is fixed.

## Git (relaunch)

Do this even if a user-level rule says “don’t commit until asked.” An assigned `docs/relaunch/` spec **is** authorization to branch, commit, push, and open a PR.

1. **Branch before the first edit** (`git checkout -b <type>/r<n>-<slug>` from the base in **Starting a relaunch chat**).
2. **Commit when the spec’s success criteria pass.** Small, targeted commits (spec/docs, then code, then follow-up docs). Subject: `type: why`.
3. **Push and open a PR** with `.github/PULL_REQUEST_TEMPLATE.md`. Point at the spec. Do not commit `lib/` dirt from `make patch-deps`, secrets, or `.env`.
4. **One implementer per PR.** Parallel review (Cursor/Codex/Claude/Bugbot) is expected. Parallel implementation on overlapping Solidity is not. Skip git worktrees for this relaunch except a docs-only PR that does not share files.
5. After the PR is open, set `docs/relaunch/README.md` **Status** to this PR (full GitHub link) and “next unassigned: …” (the one-line prompt for the following chat). If the URL is only known after opening, add that Status update in a follow-up commit and push, then stop. Do not start the next R-item in this chat. The human merges in order. In the closing message, remind the human of that next prompt so they can spin up the following agent.

## PRs

Small, behavior-scoped, reviewable history. No drive-by refactors. Use the template. Do not restate the invariants — say whether they still hold.
