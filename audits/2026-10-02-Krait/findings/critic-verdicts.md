# Krait Critic Verdicts — Phase 3

Inputs: `detector-candidates.md` (C-01…C-19), `rescan-candidates.md` (RS-1…RS-6),
`percontract-candidates.md` (PC1-1, PC3-1, PC4-1, PC4-2, PC5-1), `state-candidates.md` (STATE-1…3).
Every cited line was re-read against `src/` at `5a9ff0fe`. Evidence tier for everything below is
`[CODE-TRACE]`; no executable PoC was run (no Critical or High candidate reached the point where one
was warranted).

## Summary
- Total candidates reviewed: 33
- True Positives (Critical/High/Medium): 0
- Likely True: 0
- Downgraded to Low / Informational (real, not reportable as H/M): 3 (C-07, PC4-1, PC3-1)
- False Positives / killed by a gate: 27
- Duplicates merged: 3 (STATE-1 → C-06, STATE-2 → C-07, STATE-3 → RS-4)
- Insufficient Evidence: 0

## Verified Findings

None at Critical, High, or Medium.

## Downgraded (real mechanism, Low or Informational)

### C-07 / STATE-2: Rotating the fee collector leaves accrued rBTC under the old address
**Verdict**: DOWNGRADE → LOW
**Harm**: the protocol's own fee revenue already booked to a collector whose key is lost or compromised
cannot be redirected by `setFeeCollector`; no user loses anything.
**Proof**: `PurchaseRbtc._creditFee:181-182` credits `s_accumulatedRbtc[s_feeCollector]` at purchase time;
`PurchaseFees.setFeeCollector:78-82` writes only `s_feeCollector`; the only debit of that mapping is
`_withdrawRbtcChecksEffects(user)` reached through `DcaManager.withdrawAccumulatedRbtc`, which passes
`msg.sender`. Matches the documented rule "rBTC pays the signer — no owner rescue" (AGENTS invariant 3),
so the behaviour is consistent with the design; the consequence for the collector role is not written
down anywhere.
**Step Execution**: Gates: A=✓ B=✓ C=✓(design-consistent, not excused) D=✓ E=✓(needs owner action, but an honest one) F=✓ G=✓ H=✓(not listed)
**Rules Applied**: [R10:✓(worst state: collector key lost with a large accrued balance), R12:✓]
**Depth Evidence**: [TRACE:credit A → setFeeCollector(B) → balance(B)=0, balance(A) unchanged]

### PC4-1: `setMocOracle` is a single owner transaction that moves the effective Dex floor without limit
**Verdict**: DOWNGRADE → INFORMATIONAL (documentation / hardening)
**Harm**: none without a malicious or mistaken owner; the stated protection is narrower than described.
**Proof**: `PurchaseUniswap._validateSlippageSettings` NatSpec (`:353-358`) and
`IPurchaseUniswap.setAmountOutMinimumSafetyCheck` say no single owner transaction can widen the live
floor past the safety check. The floor is `amount × scale × percent / price` (`:277-278`), and
`setMocOracle:179-185` replaces the price source in one call with only a zero-address check. A source
reporting a larger price lowers the floor by the same factor. The swapper's `minRbtcOut`, checked on the
measured output in `PurchaseRbtc.batchBuyRbtc:80`, is unaffected.
**Step Execution**: Gates: A=✓ B=✓ C=✓ D=✓ E=✗(requires owner) F=✓ G=✓ H=✓(owner oracle risk is listed generically in AUDIT_GUIDE; the "one-transaction wall" claim is not qualified)
**Rules Applied**: [R16:✓(oracle integrity: replaceable in one call, no sanity bound against the old feed)]
**Depth Evidence**: [VARIATION:price ×1000 → floor ÷1000], [BOUNDARY:price = 0 → division panic → purchases revert]

### PC3-1: Event stablecoin figures are independent floors
**Verdict**: DOWNGRADE → INFORMATIONAL
**Harm**: none on-chain. Documented on `IPurchaseFees.FeeCredited` ("Independent floors").

## Eliminated

| ID | Title | Verdict | Reason |
|---|---|---|---|
| C-01 | Windows can be chained with no gap | FALSE POSITIVE | Gate H + C. AGENTS invariant 10: "once it expires the swapper may activate again with no daily budget"; R66 removed the daily budget on review; R110 lists a mandatory gap as a reported observation left as a product decision; `testActivationCannotBeExtendedWhileLiveButCanReopenAfterExpiry` pins it. Actor is an allowlisted role the owner can revoke. Same entry point, root cause, and impact as the recorded item |
| C-02 | Only the 97% floor binds when `minRbtcOut` is loose | FALSE POSITIVE | Gate H + C. `script/Constants.sol` states the floor is deliberately loose and "cap[s] a compromised-swapper loss at 3%"; AUDIT_GUIDE: swapper "may … submit a zero caller minimum"; missing deadline is documented at `PurchaseUniswap.sol:266-268` (also Gate A) |
| C-03 | Tail purchase reverts `InsufficientShares` | FALSE POSITIVE | Gate H. R110 #5, R39, R43, `BatchTailScheduleTest`. Reproduced numerically (45 units after 52 buys) and consistent with the recorded figures |
| C-04 | LayerBank half-up burn assumption | FALSE POSITIVE | Gate H. AUDIT_GUIDE "External assumptions", `src/layerbank/README.md` "Burn rounding", live probe. Fails closed; nothing orphaned |
| C-05 | Period cut makes a schedule due again the same day | FALSE POSITIVE | Gate H. AUDIT_GUIDE "Scheduling", R110 #2, pinned by test |
| C-06 / STATE-1 | Principal debited by request, payout may be lower | FALSE POSITIVE | Gate C + H. AGENTS invariant 11, `IDcaManager.withdrawToken` NatSpec, AUDIT_GUIDE "Schedule principal is … not a mark-to-market claim". Under no-loss conditions the gap is ≤ N share units (Gate F) |
| C-08 | Fee change applies at once | FALSE POSITIVE | Gate E + H. Owner action bounded by `MAX_FEE_RATE_CAP` (5%); AUDIT_GUIDE "Fee changes affect later purchases immediately" |
| C-09 | Floor dust uncredited | FALSE POSITIVE | Gate F + H. < 1 wei per row and per fee; measured max 27 wei in a 40-row batch |
| C-10 | Floor assumes a 1 USD stablecoin | FALSE POSITIVE | Gate H. `IPurchaseUniswap` header, AUDIT_GUIDE. Below peg fails closed |
| C-11 | One failing row or illiquid venue aborts the batch | FALSE POSITIVE | Gate H + C. Documented atomicity; the protected window removes every user-side trigger (re-checked: deposit, create, top-up, rBTC withdrawal cannot make a row fail); external illiquidity is a listed assumption |
| C-12 | Top-up allowed on a deposit-paused route | FALSE POSITIVE | Gate C. `IDcaManager.topUpFromInterest`: "remains available while deposits are paused". No new exposure: the interest is already in that market |
| C-13 | Swapper can re-activate an allowlisted path | FALSE POSITIVE | Gate H. README "Compromised swapper" gives the exact sequence |
| C-14 | rBTC payable only to the recorded account | FALSE POSITIVE | Gate C. AGENTS invariant 3. Affects only an account that cannot receive native value |
| C-15 | MoC route has no on-chain floor | FALSE POSITIVE | Gate C + H. `IDcaManager.Batch` NatSpec and leaf headers; MoC redeems at its protocol price, no pool to sandwich |
| C-16 | Zero-cash interest redeem reverts | FALSE POSITIVE | Gate B. Needs an exit fee or a rate below 1; with the live Sovryn price and Aave index one share always pays ≥ 1 unit. `withdrawToken` remains available |
| C-17 | Standing max approvals | FALSE POSITIVE | Gate A + D. No path pulls from an arbitrary approver in SwapRouter02, the Pool, or the iToken; flash-loan-as-receiver reverts (no fallback) |
| C-18 | Large schedule cap with a linear loop | FALSE POSITIVE | Gate E + D. Owner-set cap (deploy value 10); only the account that created the schedules is affected |
| C-19 | New schedule purchasable at once | FALSE POSITIVE | Gate C. `IDcaManager` header and AUDIT_GUIDE: the first buy anchors the cadence |
| RS-1 | Assignment and class irreversible | FALSE POSITIVE | Gate C + E. Stated design ("add-only … preserving exits through retired routes") |
| RS-2 | Handler self-reported validation | FALSE POSITIVE | Gate E. Only the owner can assign |
| RS-3 | No handler-side per-user book on idle | FALSE POSITIVE | Gate D via Impact Premise — Harm: MECHANISM-ONLY. No path produces a ledger/cash mismatch |
| RS-4 / STATE-3 | `purchaseAmount ≤ balance` not preserved | FALSE POSITIVE | Gate D + H. Consequence is a batch revert already covered by documented atomicity and blocked inside a window |
| RS-5 | Window is one global lock | FALSE POSITIVE | Gate C. Single slot by design (invariant 10; a private view over one slot) |
| RS-6 | Raised minimum blocks edits on low balances | FALSE POSITIVE | Gate E + D. Owner action; purchases, withdrawals and deletion still work; AUDIT_GUIDE notes minimum changes constrain future updates |
| PC1-1 | First interval can be almost a day short | FALSE POSITIVE | Gate C. UTC-midnight grid is the documented cadence model |
| PC4-2 | Allowlist does not constrain intermediates | FALSE POSITIVE | Gate E. Owner-only allowlist |
| PC5-1 | `_exchangeRate` default for future adapters | FALSE POSITIVE | Gate B + G. No in-scope adapter is lazily accruing |

**Missing Precondition** recorded for the killed Medium-rated candidates (for chain analysis):

| ID | Blocker | Type |
|---|---|---|
| C-01 | attacker must hold an allowlisted swapper key and win ordering at every `N+5` | ACCESS |
| C-02 | swapper must pass a loose `minRbtcOut` | EXTERNAL |
| C-04 | LayerBank must change burn rounding | EXTERNAL |
| C-06 | venue loss or exit fee | EXTERNAL |
| C-11 | bot must skip the window or simulation | TIMING |

Chain check: C-01's postcondition (exits and pauses locked) removes a user's defence against C-02, and
both share one precondition (compromised swapper key). The chain is bounded by the oracle floor (3% of
each due Dex purchase), does not reach MoC routes, and ends at `revokeSwapper`. It does not create the
missing precondition of any other candidate.

## Cross-feed iteration

One cycle. The state pass added nothing that changes a verdict; no verified finding exists to feed back.
