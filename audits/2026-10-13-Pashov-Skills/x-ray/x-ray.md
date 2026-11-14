# X-Ray Report

> BitChill dca-contracts | 1600 nSLOC | f414708a (`audit-pashov-skills`) | Foundry | 16/10/26

---

## 1. Protocol Overview

**What it does:** Users fund dollar-cost-averaging schedules in stablecoins, and an allowlisted bot buys rBTC for every due schedule in batches.

- **Users**: Holders of DOC, USDRIF or USDT0 who want periodic rBTC buys, with optional lending yield on the idle balance.
- **Core flow**: `createDcaSchedule` deposits into a handler; the swapper calls `batchBuyRbtc`, which debits due schedules and buys rBTC through Money on Chain or Uniswap V3.
- **Key mechanism**: One ledger (`DcaManager`) plus immutable per-(token, route) handlers that hold funds idle or lend them on LayerBank (Aave v3 fork) or Sovryn; per-user virtual shares mirror the handler's external receipt tokens.
- **Token model**: No protocol token. Stablecoins in; native rBTC or WRBTC accumulated per user; fees credited in rBTC to a collector.
- **Admin model**: `Ownable2Step` owner on every contract (a Safe, per spec), no renounce, no proxies; a swapper allowlist in `OperationsAdmin`.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Core | DcaManager, OperationsAdmin, BitChillOwnable, DcaManagerAccessControl | 617 | Schedule ledger, batch router, route registry, swapper allowlist |
| Purchase pipeline | PurchaseRbtc, PurchaseFees, PurchaseUniswap, PurchaseMoc | 507 | Batch purchase, exact-input checks, oracle floor, fee split, rBTC claims |
| Handler bases | LendingHandler, TokenHandler, IdleHandler, StablecoinSource | 266 | Deposits, withdrawals, per-user lending shares, batch funding |
| LayerBank adapters | LayerBankHandler, LayerBankDocHandlerMoc, LayerBankHandlerDex | 94 | Aave-v3 supply and exact scaled-share withdraw |
| Sovryn adapters | SovrynHandler, SovrynDocHandlerMoc, SovrynHandlerDex | 76 | iToken mint and burn |
| Idle leaves | IdleDocHandlerMoc, IdleHandlerDex | 40 | Pooled idle cash with a MoC or Uniswap route |

`src/tropykus-legacy/` is not deployed and is out of scope. `SovrynHandlerDex` is built but not deployed (per spec).

### How It Fits Together

The core trick: `DcaManager` is the only book of schedule principal, and each handler proves every external movement by measuring balance deltas, never by trusting a return value.

### Create and fund

```
DcaManager.createDcaSchedule()
├─ _validatePurchasePeriod / _validatePurchaseAmount      *token minimum must be set (G-6)*
├─ _handlerForDeposit() → OperationsAdmin.getHandler/areDepositsPaused
├─ TokenHandler.depositToken() → _depositToken()
│   ├─ safeTransferFrom(user → handler)                   *exact measured delta (G-23)*
│   └─ LendingHandler: _protocolDeposit() → s_shares += measured mint
└─ _storeNewSchedule()                                    *anchor 0 until first buy*
```

### Batch purchase

```
DcaManager.batchBuyRbtc(batch)                            *onlySwapper; no live window needed*
├─ for each id: _rbtcPurchaseChecksEffects()              *cadence, pause, balance; debit + new anchor*
└─ PurchaseRbtc.batchBuyRbtc(buyers, ids, amounts, minRbtcOut)
    ├─ _batchRetrieveStablecoin()                         *lending: per-row clamp, exact share burn*
    ├─ _calculateFeeAndNetWeights(clamped amounts)
    ├─ _purchaseRbtc()  → MoC redeemFreeDoc | SwapRouter02.exactInput(max(minRbtcOut, oracle floor))
    ├─ exact input spent; Q ≥ minRbtcOut                  *measured deltas (G-28, G-29)*
    └─ _creditPurchases() + _creditFee()                  *floor(Q·w/G) per row*
```

### Withdraw principal

```
DcaManager.withdrawToken()                                *window-guarded, owner-only*
├─ debit requested amount                                 *not the amount paid*
└─ TokenHandler.withdrawToken()
    └─ LendingHandler._withdrawToken()
        ├─ clamp to value of all user shares
        ├─ _redeemShares() → _measuredProtocolRedeem()    *exact burn (G-26)*
        └─ safeTransfer(user, measured cash)
```

### Claim rBTC

```
DcaManager.withdrawAllAccumulatedRbtc(tokens, routes)
└─ PurchaseRbtc.withdrawAccumulatedRbtc(msg.sender)
    ├─ _withdrawRbtcChecksEffects()                       *leaves sentinel 1 (I-14)*
    └─ _withdrawRbtc() → [WRBTC.withdraw] → user.call{value}
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator** with **DEX integrator** characteristics

Handlers deposit user funds into external lending markets and track per-user shares and interest (vault signals); the purchase path routes swaps through Uniswap V3 with an oracle floor (swap-execution signals). The DCA scheduler itself matches no standard profile.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Owner | Trusted | Instant: route registration, one-time handler assignment, deposit pause, swapper list, fees, collector, oracle, floor, path allowlist, manager limits. Two-step transfer; no renounce; no timelock in code. |
| Swapper | Bounded (liveness and batch selection) | Opens a 5-block window, executes batches with any `minRbtcOut` (zero allowed), switches among allowlisted paths. Cannot move principal or redirect buyers. |
| Schedule owner | Bounded (own schedules only) | Creates, funds, edits, pauses, deletes and withdraws its schedules; tops up from its own interest. |
| Pending owner | Bounded (one call) | `acceptOwnership` only. |

**Adversary Ranking**:

1. **MEV searcher** — Dex batches settle against public pools with a loose oracle floor (97% at launch, per spec), so sandwiching is the main value-extraction threat.
2. **Leaked swapper key** — The key controls the protected window, batch timing, `minRbtcOut` and the active path.
3. **Lending-market actors** — Borrowers and market governance decide the liquidity and exchange rate that every lending exit and purchase depends on.
4. **Compromised owner** — Instant oracle, floor, fee and path powers within setter bounds.
5. **Schedule owner** — Can change batch inputs and cadence for its own schedules between quote and execution.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Owner → configuration** — No on-chain delay; `setMocOracle` (`PurchaseUniswap.sol:179`) swaps the floor's price source in one call. *Git signal: access_control area has 304 commits.*

- **Swapper → DcaManager** — Allowlist check per call (`DcaManager.sol:75`); `revokeSwapper` is instant but leaves a live window and the chosen path in place (X-5).

- **DcaManager → handlers** — `onlyDcaManager` on every fund-moving handler call; assignment is once per pair, and the registry does not prove the handler's manager is canonical (X-4).

- **Handlers → external venues** — Measured deltas on every movement; unlimited standing approvals to SwapRouter02 and lending spenders (`LendingHandler.sol:116`, `PurchaseUniswap.sol:327`).

### Key Attack Surfaces

- **Batch output bound vs. movable batch input** &nbsp;&#91;[X-3](invariants.md#x-3), [I-5](invariants.md#i-5), [G-29](invariants.md#g-29)&#93; — `_batchBuyRbtc:493-515` reads amounts at execution while `minRbtcOut` is an absolute figure (`PurchaseRbtc.sol:76`) and `depositToken:169`/`createDcaSchedule:123` lack the window guard. Worth tracing every way a batch's total input can change after the bot quotes.

- **Nominal principal vs. lending share value** &nbsp;&#91;[X-2](invariants.md#x-2), [X-3](invariants.md#x-3), [E-3](invariants.md#e-3)&#93; — `LendingHandler._batchRetrieveStablecoin:171-179` and `_withdrawToken:144-147` clamp against the user's whole share position while `DcaManager` debits per schedule. Worth checking how one user's several schedules interact after an exchange-rate fall.

- **Exact share-consumption check vs. venue burn rules** &nbsp;&#91;[G-26](invariants.md#g-26), [I-1](invariants.md#i-1)&#93; — `_measuredProtocolRedeem:332` needs an exact burn; `LayerBankHandler._underlyingForExactScaledBurn:104-111` assumes half-up rounding and `SovrynHandler._protocolRedeem:66` relies on iToken burn behaviour. Worth confirming each venue's rounding and small-remainder handling.

- **Swapper powers around the window** &nbsp;&#91;[I-13](invariants.md#i-13), [X-5](invariants.md#x-5), [I-19](invariants.md#i-19)&#93; — `activateProtectedPurchaseWindow:342` can re-open at N+5, and `setPurchasePath:148` is open to any swapper at any time. Worth tracing what a leaked key can do before and after revocation.

- **Cadence anchor across edits** &nbsp;&#91;[I-10](invariants.md#i-10), [I-12](invariants.md#i-12)&#93; — `_rbtcPurchaseChecksEffects:546-558` recomputes from the stored anchor after `updatePurchasePeriod:203`; delete and re-create starts at anchor 0. Worth bounding purchases per schedule and per user per day.

- **Uniswap floor inputs** &nbsp;&#91;[G-32](invariants.md#g-32), [I-18](invariants.md#i-18)&#93; — `_getAmountOutLowerBound:275-278` uses only the `isValid` flag, discards the publication block and prices each stablecoin at $1. Worth checking the floor under fast price moves and a depeg.

- **MoC route output bound** &nbsp;&#91;[G-29](invariants.md#g-29)&#93; — `PurchaseMoc._purchaseRbtc:43-58` ignores `minRbtcOut`; only the caller minimum in `PurchaseRbtc.sol:76` binds. Worth confirming how `redeemFreeDoc` prices and what external caps it applies.

- **Deposit write ordering** — `DcaManager.depositToken:172-174` computes the new balance before the handler call and stores it after; batch functions are not `nonReentrant`. Worth confirming no venue or token callback can reach a purchase.

- **Owner operational powers** &nbsp;&#91;[I-4](invariants.md#i-4), [I-6](invariants.md#i-6), [I-8](invariants.md#i-8), [X-4](invariants.md#x-4)&#93; — Every setter is instant; raised minimums and a lowered schedule cap do not touch existing schedules. Worth reviewing which settings change live schedule behaviour.

### Protocol-Type Concerns

**As a Yield Aggregator:**
- `LendingHandler.sol:252` rounds share debits up and `:266` rounds values down; per-user shares mirror external receipt tokens, so there is no internal share price to inflate.
- `LayerBankHandler.sol:82-86` assumes the liquidity index stays ≥ RAY; below it the floor-then-+1 sizing is not exact.

**As a DEX integrator:**
- `PurchaseUniswap.sol:249-256` checks every intermediate token's router balance; no swap deadline exists (`:266-268`).

### Temporal Risk Profile

**Deployment & Initialization:**
- Handler assignment is permanent (I-15); a wrong assignment needs a new route index, and the token minimum must be set before assignment (per spec).
- The deploy EOA owns every contract until the Safe calls `acceptOwnership` (per spec).

**Market Stress:**
- Lending illiquidity or a venue cap reverts the whole batch, and `batchBuyRbtcAcrossHandlers:361-367` reverts every handler with it.

**Deprecation:**
- Retired routes stay assigned (I-15); recovery from a defective handler is a new route and manual user exit (per spec).

### Composability & Dependency Risks

**Dependency Risk Map:**

> **MoC BTC/USD oracle** — via `PurchaseUniswap._getAmountOutLowerBound`
> - Assumes: `getPriceInfo` price is current and non-zero
> - Validates: `isValid` flag only
> - Mutability: Replaceable instantly by owner (`setMocOracle`)
> - On failure: revert (`PurchaseUniswap__OutdatedPrice`)

> **Uniswap V3 SwapRouter02** — via `PurchaseUniswap._purchaseRbtc`
> - Assumes: router enforces `amountOutMinimum`
> - Validates: measured WRBTC delta, exact input, intermediate balances
> - Mutability: Immutable router; pools are public
> - On failure: revert

> **Money on Chain proxy** — via `PurchaseMoc._purchaseRbtc`
> - Assumes: `redeemFreeDoc` consumes the full DOC amount and pays rBTC
> - Validates: exact input, measured native delta, caller minimum
> - Mutability: Governed by Money on Chain
> - On failure: revert

> **LayerBank Pool / aToken** — via `LayerBankHandler`
> - Assumes: half-up scaled burn, index ≥ RAY, cash available
> - Validates: exact scaled-share delta, measured cash
> - Mutability: Upgradeable by LayerBank (per spec: instant EOA upgrade)
> - On failure: revert

> **Sovryn iDOC** — via `SovrynHandler`
> - Assumes: `burn` burns exactly the requested shares
> - Validates: exact iToken delta, measured cash
> - Mutability: Governed (per spec: 24-48h Bitocracy timelock)
> - On failure: revert

**Token Assumptions** *(unvalidated only)*:
- Stablecoins: assumed worth $1 on the Dex floor — a depeg moves the floor away from fair value.
- USDRIF, USDT0: upgradeable proxies (per spec) — behaviour can change after deployment.
- Native rBTC recipients: assumed to accept rBTC — a rejecting account cannot claim.

**Shared State Exposure**:
- Idle and LayerBank USDT0 and USDRIF batches route through the same USDT0/WRBTC 0.30% pool (per spec), so batches in one call move each other's price.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **37 Enforced Guards** (`G-1` … `G-37`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **22 Single-Contract Invariants** (`I-1` … `I-22`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **6 Cross-Contract Invariants** (`X-1` … `X-6`) — caller/callee pairs that cross scope boundaries
> - **3 Economic Invariants** (`E-1` … `E-3`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-2]`, `[I-12]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md`, `src/layerbank/README.md`, `src/idle/README.md` |
| NatSpec | Present on every in-scope contract | Most functions carry `@notice`/`@dev`, with rationale |
| Spec/Whitepaper | Present | `AUDIT_GUIDE.md`, `docs/relaunch/` design notes (R-specs) |
| Inline Comments | Thorough | Ordering, gas and safety reasons stated next to the code |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 130 | File scan (always reliable) |
| Test functions | 882 | File scan (always reliable) |
| Line coverage | Partial: DcaManager 86%, LendingHandler 98%, PurchaseRbtc / PurchaseFees / TokenHandler 100%, PurchaseUniswap 87%, OperationsAdmin 63% | `forge coverage --ir-minimum`, mainnet-debug excluded |
| Branch coverage | Partial: DcaManager 61%, PurchaseUniswap 64%, OperationsAdmin 7%; LendingHandler / PurchaseRbtc / PurchaseFees 100% | Same run |

593 tests passed and 78 failed in this run: most failing suites need lane variables (`SWAP_TYPE`, `LENDING_PROTOCOL`) that the repo's `make` targets set, so the figures above undercount coverage.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 882 functions (incl. below) | broad |
| Fork | 2 files | e.g. `test/mainnet-debug/DeleteDcaScheduleDebugTest.t.sol` (excluded from the coverage run) |
| Stateless Fuzz | 14 | see `test/` |
| Stateful Fuzz (Foundry) | 11 | see `test/` |
| Stateful Fuzz (Echidna / Medusa) | 0 | none |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none |

### Gaps

- No Echidna or Medusa campaigns for the share and fee accounting.
- No formal verification of the fee formula, the share conversions or the cadence arithmetic.

---

## 6. Developer & Git History

> Repo shape: normal_dev — 446 source-touching commits of 1171 between 2024-02-02 and 2026-10-16.

Analyzed branch: `audit-pashov-skills` at `f414708a`; `src/` is identical to `d5c09c32`.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Ynyesto | 1022 | +18296 / -13688 | 98.4% |
| arynyestos | 90 | +219 / -219 | 1.2% |
| Claude | 14 | +80 / -85 | 0.4% |

Other author names (4) touched no source. Some names may be aliases of one developer; could not confirm.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 8 | Single-dev in practice (98% of source lines) |
| Merge commits | 34 of 1171 (2.9%) | Little formal review signal |
| Repo age | 2024-02-02 → 2026-10-16 | ~32 months |
| Recent source activity (30d) | 143 commits | Late burst before audit |
| Test co-change rate | 59.6% | Co-modification of test files, not coverage |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/DcaManager.sol | 175 | Highest churn — prioritize review |
| src/PurchaseUniswap.sol | 100 | Floor and path logic |
| src/PurchaseRbtc.sol | 80 | Purchase pipeline |
| src/LendingErc20Handler.sol | 60 | Earlier path of the lending base (rename to LendingHandler.sol not confirmed) |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals in a commit: message keywords (fix, bug, reentrancy, overflow...), diff patterns (deletes code, changes `require`/`assert`, touches access control or accounting), and change shape (focused = higher). **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 7f5d0072 | 2026-08-16 | fix: stop owner rescue of another account's rBTC | 20 | loosens access control, token transfer logic |
| ada67f39 | 2026-08-16 | fix: derive schedule ids from a monotonic nonce | 18 | removes runtime guard, accounting |
| ae5d2441 | 2026-09-09 | docs: add security review handoff | 17 | security language, accounting |
| 0ac4a18a | 2026-09-09 | fix: skip missed purchase slots by UTC day | 17 | 204 lines, cadence logic |
| 02f6c63d | 2026-08-27 | fix: live deploy from the Foundry EOA, then propose the Safe | 16 | tightens access control |
| 87d72e01 | 2026-08-16 | fix: restore diagnostic purchase reverts and re-validate deposit schedule ids | 16 | access control, transfers |
| c0792d4f | 2026-08-15 | fix: skip gas-only purchase checks and credit deposits after the pull | 15 | loosens checks, accounting |
| 3481500d | 2026-09-26 | perf: skip the overflow checks two widening adds cannot fail (R89) | 15 | unchecked arithmetic, no test change |
| e37bfd9e | 2026-09-26 | perf: skip the same impossible overflow checks off the purchase path (R89) | 14 | unchecked arithmetic, no test change |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 330 | DcaManager, LendingHandler, PurchaseRbtc |
| access_control | 304 | DcaManager, OperationsAdmin, PurchaseUniswap |
| state_machines | 287 | DcaManager, LendingHandler, OperationsAdmin |
| oracle_price | 213 | PurchaseUniswap, handler leaves |
| signatures | 195 | DcaManager (keyword match; no signature code in scope) |

### Security Observations

- **Single-developer concentration** — one author wrote 98.4% of source lines.
- **Few merge commits** — 34 of 1171, so most changes landed without a merge-based review.
- **Late burst** — 143 source commits in the last 30 days, including the R114 lending clamp (`aa958db4`, `a651e3ab`, `d7e2feaf`, 2026-10-07).
- **Unchecked arithmetic added late** — `3481500d` and `e37bfd9e` (R89) removed overflow checks with no test change.
- **Fixes without tests** — the git analysis puts the fix-without-test rate at 30%.
- **No technical-debt markers** — no TODO/FIXME/HACK in scope.

### Cross-Reference Synthesis

- **DcaManager is #1 in churn and hosts four attack surfaces** → `_batchBuyRbtc`, `_rbtcPurchaseChecksEffects`, `depositToken` and the window are the highest-leverage review.
- **R114 clamp landed after both automated audits (per spec)** → it is the code behind X-2, X-3 and E-3 (On-chain=No).
- **`0ac4a18a` cadence fix + test `5833bc6b` (period cut makes a schedule due again)** → I-12 is a known, pinned behaviour worth bounding.

---

## X-Ray Verdict

**ADEQUATE** — Tests reach unit + fuzz + invariant and the docs are thorough, but every owner action is instant with no timelock in code (multisig ownership is per spec only).

**Structural facts:**
1. 1,600 nSLOC in 20 files across 6 subsystems; no proxies or initializers.
2. 882 test functions in 130 files, including 14 stateless fuzz and 11 Foundry invariant tests; no Echidna, Medusa or formal verification.
3. One author wrote 98.4% of source lines; 34 of 1171 commits are merges.
4. 143 source commits landed in the 30 days before `f414708a`.
5. 9 contracts carry an owner with instant setters; 1 swapper allowlist gates purchases.
