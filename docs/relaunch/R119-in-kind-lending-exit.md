# R119 — Exit a lending position in kind

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

A user can leave a lending route even when the venue cannot pay cash. A new user function moves the
caller's whole position on one token and lending route out of BitChill as the venue's own receipt
token (LayerBank aTokens, Sovryn iTokens), and zeroes the caller's schedule balances on that route.
The user then redeems at the venue directly, whenever the venue allows. BitChill holds nothing for
them, so no buffer or operator action is needed.

## Background

V1 users are stuck in Sovryn's DOC pool today, for three reasons that stack:

1. **Illiquidity (August–October 2026).** iSUSD was ~99.99% utilized. A withdrawal larger than the
   pool's idle DOC reverts inside the venue.
2. **Delayed withdrawals (since 26 October 2026).** SIP-0096 queues voluntary lending withdrawals for
   24 hours, paid to the recorded receiver. V1's handler burns to itself, receives nothing, then tries
   to pay the user from its own balance and reverts.
3. **Protocol pause (since 31 October 2026).** After an exploit of Sovryn's swap converter registry,
   every iToken call reverts.

The only way out for V1 users is a DOC buffer that BitChill funds and cannot recover, because V1 has
no sweep. V2 has the same exposure: `LendingHandler._withdrawToken` and `withdrawInterest` redeem onto
the handler, and `_measuredProtocolRedeem` requires exact share consumption, so (1) and (2) revert in
V2 too (invariant 11 names async request/claim queues as unsupported).

The receipt token is the user's claim on the venue. Handing it over removes BitChill from the path in
(1) and (2): the user can wait for liquidity, or go through the venue's queue, in their own name. It
does not help with (3) if the venue's pause also blocks receipt-token transfers. That limit must be
documented, not engineered around.

Facts the implementer relies on, at pin `6b2ed77`:

- `LendingHandler.s_shares[user]` is in the venue's receipt-share units: `scaledBalanceOf` for
  LayerBank, `balanceOf` for Sovryn (invariant 11). One handler serves one token on one route, so
  `s_shares[user]` is the user's whole position there, principal and interest together.
- `DcaManager._withdrawToken` debits the requested amount and ignores what the handler pays out. The
  core does not need to know how the handler pays.
- `_lockedPrincipal(user, token, routeIndex)` already walks `s_scheduleIds[user][token]` and filters
  by route. The schedule cap is `MAX_SCHEDULES_PER_TOKEN` (10 at launch).
- DcaManager runtime is 13,236 B (margin 11,340 B); `LayerBankDocHandlerMoc` 11,316 B,
  `LayerBankHandlerDex` 16,717 B (`forge build --sizes`, default profile).

## Open product decisions

Recommendations are in bold. Ask the owner to confirm each before Solidity.

1. **Trigger.** **(a) An explicit user function, callable at any time.** (b) Automatic fallback: try
   the cash redeem and pay in kind if the venue reverts. (b) needs a `try`/`catch` around venue calls
   that would also catch unrelated reverts and out-of-gas, and it hands users a token they did not ask
   for. The front-end can offer (a) when a simulated cash withdrawal fails.
2. **Granularity.** **Whole position per token and lending route** (all of the caller's shares in that
   handler, so interest is included). The alternative, a per-schedule amount in kind, needs share
   rounding against a partial interest split and adds surface for an emergency path.
3. **Schedules after the exit.** **Keep them, with `tokenBalance` set to 0**, as a full
   `withdrawToken` does today. The user can top them up later or delete them. Alternative: delete them.
4. **Protected window.** **Blocked during the window** (add the function to invariant 10's guarded
   set), like every other withdrawal. A batch in flight cannot then lose rows mid-window.
5. **Sovryn.** If `src/sovryn/` stays in the audit scope, the Sovryn adapter implements the hook too.
   If the owner drops Sovryn from the scope, only LayerBank and the base implement it.

## Scope

Written for the recommended answers. Adjust if the owner decides otherwise.

- [ ] `IDcaManager` / `DcaManager`: `exitLendingPositionInKind(address token, uint256 routeIndex)`,
      `whenUserMutationsAllowed nonReentrant` (invariants 6 and 10).
  - Revert unless the route is a lending route (`_checkTokenIsLent`) and has a handler.
  - Walk `s_scheduleIds[msg.sender][token]`. For each id on `routeIndex`, reach the schedule through
    `_callersSchedule` (invariant 8: no direct `s_dcaSchedules` read in a mutator), set
    `tokenBalance` to 0 and emit `DcaManager__TokenBalanceUpdated`, before the handler call (CEI, as
    R118 does for deposits and withdrawals).
  - Call `ILendingHandler(handler).exitInKind(msg.sender)`.
  - Revert if the caller has no shares in that handler, so an empty call is not a silent success.
- [ ] `ILendingHandler` / `LendingHandler`: `exitInKind(address user) onlyDcaManager returns (uint256 shares)`.
  - Read `s_shares[user]`, set it to 0 through `_setUserShares` (invariant 14), then transfer the
    receipt token through a new adapter hook `_protocolTransferShares(address to, uint256 shares)`.
  - Measure the handler's receipt-share balance around the hook and require it to fall by exactly
    `shares` (extend invariant 11 to in-kind exits). The handler's stablecoin balance must not change.
  - Emit one new event, `LendingHandler__PositionExitedInKind(address indexed user, address indexed receiptToken, uint256 shares)`.
- [ ] `LayerBankHandler._protocolTransferShares`: transfer aTokens so that exactly `shares` scaled
      units move. An aToken `transfer` takes underlying units and scales them with the live index, so
      reuse or mirror `_underlyingForExactScaledBurn` and let the measurement in the base be the
      judge. Confirm the rounding on a fork before choosing the formula.
- [ ] `SovrynHandler._protocolTransferShares` (only if decision 5 keeps Sovryn): iToken `transfer`.
- [ ] `AGENTS.md`: invariant 10 lists the new function; invariant 11 covers in-kind exits.
- [ ] `AUDIT_GUIDE.md`: trust model gains "a user can always take their lending position in kind,
      unless the venue blocks receipt-token transfers", with the pause limit stated.

## Out of scope

- [ ] Automatic fallback inside `withdrawToken` / `withdrawInterest` (decision 1b).
- [ ] Any async request/claim lifecycle, including purchases from a venue with delayed withdrawals.
      Such a venue needs its own handler and route, not a change here.
- [ ] Moving a position in kind into another route or handler (no migration).
- [ ] Idle routes: the handler already holds the stablecoin itself.
- [ ] V1 contracts and the V1 withdrawal buffer.
- [ ] Re-enabling Sovryn, deploy scripts and live configuration.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `src/LendingHandler.sol`, `src/interfaces/ILendingHandler.sol`
- `src/layerbank/LayerBankHandler.sol`, `src/layerbank/ILayerBankAToken.sol` (only if the hook needs a view it lacks)
- `src/sovryn/SovrynHandler.sol` (decision 5)
- `test/mocks/` lending mocks: an illiquid mode (redeem reverts, transfers work) and a paused mode (both revert)
- `test/unit/` lending and DcaManager suites; the stateful invariant handler in `test/ai-generated/fuzz/`
- `AGENTS.md`, `AUDIT_GUIDE.md`

## Required tests

- Unit, each lending protocol lane (`LENDING_PROTOCOL=layerbank`, and `sovryn` if decision 5 keeps it):
  - With the venue illiquid, `withdrawToken` reverts and `exitLendingPositionInKind` succeeds. The user
    receives receipt tokens worth their principal plus interest at the current index, their shares are
    0, every schedule on the route has `tokenBalance == 0`, and schedules on other routes are untouched.
  - Other users' shares, the handler's total receipt-share balance minus the exited shares, and the
    handler's stablecoin balance are unchanged.
  - Reverts: idle route, unassigned pair, zero shares, during the protected window (`N` to `N + 4`;
    succeeds at `N + 5`), re-entry from a token callback.
  - A share-consumption mismatch in the hook reverts the whole call, schedule balances included.
  - Event order: `TokenBalanceUpdated` for each schedule, then `UserSharesUpdated`, then
    `PositionExitedInKind`.
  - After the exit, a top-up and a purchase on a kept schedule work normally.
- Stateful invariants: add the exit to the fuzz handler. The sum of `s_shares` still equals the
  handler's receipt-share balance after any sequence that includes exits.
- Fork (`make fork-layerbank`): exit in kind on the live LayerBank pool, then redeem the received
  aTokens from the user's address through the LayerBank pool directly. Record the transfer rounding
  observed. Record whether LayerBank's paused and frozen reserve states block aToken transfers.
- Full gates before push: `make check`, `make check-deploy`, `make fork-layerbank`, and
  `make fork-sovryn` if decision 5 keeps Sovryn.

## Success criteria

- [ ] Decisions 1–5 answered and recorded in this spec.
- [ ] A user on a lending route can leave with their whole position when the venue cannot pay cash,
      with no BitChill funds or operator action involved.
- [ ] Invariants 6, 8, 10, 11 and 14 hold as amended.
- [ ] Runtime sizes reported for DcaManager and every lending leaf; all within EIP-170.
- [ ] The venue-pause limit is stated in `AUDIT_GUIDE.md`.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold unless this spec explicitly changes one.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: one new `DcaManager` function, one new `ILendingHandler` function, one new event. Consumers
  regenerate ABIs.
- Scripts: none.
- Cutover: consumer issues on front-end (offer the exit when a simulated cash withdrawal fails, and
  explain the receipt token and how to redeem it at the venue), data-api and bitchill-monitoring
  (index the new event; schedule balances already follow `TokenBalanceUpdated`), swapper-bot
  (confirm that it skips zero-balance schedules), docs (user guide entry).
- Audit: lands before the audit freeze, so it is in the frozen scope.
