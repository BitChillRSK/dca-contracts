# Krait Second Opinion — BitChill DCA contracts

27 killed findings: 25 re-examined, 2 skipped (dismissed as generic best practice or out of context,
which are not re-opened). Result: 1 revived for manual review, 1 folded into a systemic pattern,
23 confirmed. Three further notes come from findings the verification step downgraded rather than killed.

Revived items are flags for a human reviewer. They are not verified vulnerabilities.

## Systemic Patterns

### A leaked swapper key reaches further than any single item suggests

**What's happening**: three behaviours that were each dismissed as documented share one precondition, a
compromised swapper key. The swapper can re-open the five-block protected window the moment it expires,
it can submit Dex batches with a zero minimum so only the 97% oracle floor binds, and it can switch the
active Dex path among the ones governance allowlisted. Together: users on Dex routes cannot pause,
withdraw or delete while the windows are chained, and each schedule that comes due during that time can
be filled up to 3% below the oracle price.

**Affected areas**:
- `src/DcaManager.sol:347-358` — a new window may start in the same block the previous one ends
- `src/PurchaseUniswap.sol:231-237` — `amountOutMinimum` falls back to the oracle floor when the caller minimum is zero
- `src/PurchaseUniswap.sol:148-160` — any swapper may activate any allowlisted path

**Why individual analysis missed it**: each piece is written down as accepted on its own (window re-opening
in the invariants, the 3% cap in the deploy constants, path switching in the README). The combination,
where the lock removes the user's way out of the loose fill, is not described in one place.

**Risk if real**: LOW. The loss is capped at 3% of one purchase per due Dex schedule per period, MoC routes
are unaffected, users can still compete for inclusion in the first block after each window, and
`revokeSwapper` ends it.

**Verify**:
- [ ] Confirm the incident runbook orders `revokeSwapper` first and states the expected time for the Safe to execute it
- [ ] Decide whether a mandatory gap between windows (the open product decision recorded in R110) should be closed before launch; a gap of at least five blocks guarantees an exit interval regardless of transaction ordering
- [ ] Confirm monitoring alerts on consecutive `ProtectedPurchaseWindowActivated` events with no purchase between them

### Dex safety parameters are all single-step owner actions

**What's happening**: on a Dex handler the owner can replace the price oracle, lower the floor (two calls),
allowlist a new path, and, through `OperationsAdmin`, add a swapper. The documented trust model says a
malicious owner can make unsafe oracle, floor and path decisions. What bounds the damage is structural:
only amounts that are due for purchase can be routed, principal can only leave to its owner, and assigned
handlers cannot be replaced.

**Affected areas**:
- `src/PurchaseUniswap.sol:179-185` — oracle replaced in one call, zero-address check only
- `src/PurchaseUniswap.sol:163-176` — floor and its lower bound
- `src/PurchaseUniswap.sol:132-145` — path allowlist
- `src/OperationsAdmin.sol:136-139` — swapper allowlist

**Why individual analysis missed it**: each setter was dismissed as trusted-owner configuration.

**Risk if real**: LOW under the stated trust model (governance is a Safe). It becomes relevant during the
period the README describes in which the deploying EOA still owns every contract before the Safe accepts.

**Verify**:
- [ ] Confirm the Safe has accepted ownership of all nine contracts before the bot is enabled
- [ ] Decide whether the Safe should sit behind a timelock for the four setters above

## Revisit — No minimum gap between protected purchase windows

**File**: `src/DcaManager.sol:347-358`
**Suggested severity**: LOW (product decision)

**What the finding claims**: a swapper can activate a window at block `N` and again at `N+5`, indefinitely.
While it keeps winning the first position in each `N+5` block, principal and interest withdrawals,
pausing, edits and deletion stay refused for every user on every route.

**Why it was dismissed**: the invariants file states that a window may be re-opened after expiry with no
daily budget, a test pins that behaviour, and an internal review already recorded "a mandatory gap
between windows" as an observation left as a product decision.

**Why that dismissal may be wrong**: it is correct as a known-issue ruling. It is revived only because the
decision is still open and the code is immutable once deployed: the cheapest moment to settle it is
before cutover. A single comparison in `activateProtectedPurchaseWindow` (refuse activation before
`s_userMutationsAllowedFromBlock + PROTECTED_PURCHASE_WINDOW_BLOCKS`) would give users a guaranteed
five-block exit interval after every window, at the cost of halving the bot's worst-case retry rate.

**Audit-trail signal that justified revival**: the killed candidate's postcondition ("exits and pauses
locked") is the missing defence for the loose-floor candidate; the two compose (see the first systemic
pattern).

**Impact if real**: delayed exits and up to 3% on due Dex purchases until the swapper is revoked.

**Verify**:
- [ ] Check whether the bot ever needs two windows closer than ten blocks apart in normal operation
- [ ] If not, weigh adding the gap against invariant 10's "do not add a lock branch" rule (the gap is in the activation path, not the purchase path)
- [ ] If the decision is to keep the current behaviour, state the worst case in `AUDIT_GUIDE.md` next to the window description

## Note — The "one-transaction wall" on the Dex floor does not cover the oracle setter

**File**: `src/PurchaseUniswap.sol:179-185`, `:353-358`; `src/interfaces/IPurchaseUniswap.sol:122-128`

**Observation**: the NatSpec says no single owner transaction can widen the live floor past the safety
check. `setMocOracle` changes the price the floor is computed from in one call, so it moves the effective
floor without touching either percentage. Either qualify the two comments ("…through the percentage
setters") or bound the new oracle's price against the current one at the time of the switch.

## Note — Fee credits stay with the collector address that was current when they were earned

**File**: `src/PurchaseFees.sol:78-82`, `src/PurchaseRbtc.sol:176-184`

**Observation**: `setFeeCollector` redirects future fees only. Rotating away from a lost or compromised
collector does not recover what is already booked to it. Operationally: withdraw the collector's balance
on every handler before rotating, and say so in the runbook.

## Note — Two reviewer-facing documents describe behaviour the code no longer has (outside `src/`)

**File**: `AUDIT_GUIDE.md:79`, `DEPENDENCY_MODIFICATIONS.md:12`

**Observation**: the audit guide says "Idle handlers keep per-user balances"; `IdleHandler` has no per-user
book and says so in its own header. `DEPENDENCY_MODIFICATIONS.md` says there is no `[profile.deploy]`,
while `foundry.toml` defines it and the README requires it for every broadcast. Neither affects the
contracts; the first one is in the document the README names as the reviewer's starting point.

---

**Confirmed kills**: 23 of 25 re-examined findings were correctly dismissed.

<details>
<summary>View confirmed kills</summary>

| # | Finding | Dismissed because | Confirmed because |
|---|---------|-------------------|-------------------|
| 1 | Dex fill bounded only by the 97% floor | Documented design with a stated 3% cap | The floor is oracle-based, so pool manipulation cannot push it lower; the cap holds |
| 2 | Last purchase of a lending position reverts | Recorded and accepted internally | Re-simulated: shortfall is share-unit dust; a clamp would move it onto other buyers |
| 3 | LayerBank burn-rounding assumption | Documented with a live probe | Sizing is exact under half-up for every sampled index; under round-up it reverts, never orphans |
| 4 | Same-day second purchase after a period cut | Documented, owner-only | One extra purchase on the owner's own balance; no loop |
| 5 | Principal debited by request, payout may be lower | Documented accounting rule | Without a venue loss the gap is dust; re-crediting would create principal with no backing |
| 6 | Fee change applies at once | Trusted owner, 5% cap | Cap enforced in the constructor and the setter |
| 7 | Floor dust uncredited | Economically insignificant | Under one wei per row; rounding direction is not attacker-controlled; no accumulation path |
| 8 | Floor assumes a 1 USD stablecoin | Documented precondition | Below peg stops swaps; above peg the caller minimum still binds |
| 9 | One failing row aborts the batch | Documented; window mitigates | No open user action can turn a passing row into a failing one inside a window |
| 10 | Top-up allowed while deposits are paused | Documented | Converts interest already in the market; adds no exposure |
| 11 | Swapper can re-activate an allowlisted path | Documented with the response order | Paths are governance-approved; floor still binds |
| 12 | rBTC payable only to the recorded account | Documented rule | Affects only an account that cannot receive native value |
| 13 | MoC route has no on-chain floor | Documented | No pool to move; caller minimum is checked on measured output |
| 14 | Zero-cash interest redeem reverts | Needs conditions that do not exist today | One share pays at least one unit at any rate ≥ 1; principal-only exit stays open |
| 15 | Large schedule cap with a linear loop | Owner setting, self-inflicted | Deploy value is 10; no other account is affected |
| 16 | New schedule purchasable at once | Documented cadence model | — |
| 17 | Assignment irreversible | Stated design | Protects exits through retired routes |
| 18 | Handler self-reported validation | Owner-only action | An unassigned handler has no authority |
| 19 | No per-user book on idle handlers | No consequence could be stated | Deposit and purchase deltas are exact; withdrawals bounded by the schedule balance |
| 20 | `purchaseAmount ≤ balance` not preserved | Consequence is a documented batch revert | Withdrawals are blocked inside a window |
| 21 | Window is a global lock | Stated design | — |
| 22 | Raised minimum blocks edits on low balances | Owner action, no loss | Purchases and exits unaffected |
| 23 | First interval can be almost a day short | Documented UTC grid | — |

Not re-opened: unlimited standing approvals (generic best practice) and the future-adapter exchange-rate
default (no such adapter in scope). The unconstrained path-allowlist item is covered by the second
systemic pattern.
</details>
