# R97 — Redeem lending exits straight to the user

Status: **implemented** · GitHub [#163](https://github.com/BitChillRSK/dca-contracts/pull/163) · Assigned: yes · Optional/further-review: no · Stack on: R96 ([#162](https://github.com/BitChillRSK/dca-contracts/pull/162))

## Objective

Principal and interest withdrawals from a lending handler redeem at the market with the user as the
receiver. The handler no longer receives the cash and re-sends it. Batch purchases still redeem onto the
handler, which is where the purchase needs the cash.

To keep the class diagram honest, `TokenHandler._withdrawToken` becomes abstract. Its
transfer-and-measure body moves into `IdleErc20Handler`, the only handler that pays out of its own
pooled cash.

## Background

### The decisions this reverses

**[R28](./R28-lending-erc20-handler.md) (PR 19, human decision):** "Always redeem onto the
handler … Sovryn `burn(user)` is not worth a `recipient` parameter on the shared hook … Do not add
`withdraw(..., user)` on LayerBank."

That call was made before [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md) existed, on
Foundry numbers. Every lending exit today sends the handler's stablecoin balance 0 → X (the redeem) → 0
(the transfer). Foundry's EIP-2200 refund hides most of that round trip: about 2.3k at transaction
level. Rootstock charges `SET` 20,000 + `CLEAR` 5,000 − 15,000 refund = **10,000**, with no restore
refund. On top of that come:
- a transfer call (700 on Rootstock);
- on the principal path, `TokenHandler._withdrawToken`'s two `balanceOf` calls;
- their reads;
- one extra `Transfer` log.

**[R21](./R21-fee-on-transfer-deposits.md):** "Recipient-side measurement would brick live 1:1
withdraws for any recipient whose balance does not increase in the same call, for a token class we do
not support."

After this PR, the lending exit measures the user's balance. `AGENTS.md` invariant 1 already allows
that: "or the user's balance when paying the user". The class R21 describes is a stablecoin that
credits the recipient nothing, such as one with a 100% outbound fee:
- **Before:** that token would have let a withdrawal report success while paying the user nothing.
- **After:** it reverts `TokenLending__ZeroStablecoinReceived` and leaves the position intact.

R21 itself says that token "would in isolation be better served by reverting". The listed stablecoins are
plain ERC-20s, and a handler's stablecoin is fixed at construction. Idle withdrawals keep measuring the
handler's own balance, exactly as today.

**Human decision, 2026-09-27:** implement. The review's report named both reversals and the 100% fee
trade-off before the decision.

### Prototype measurement (2026-09-27)

This used mocks under the `default` profile, on a throwaway harness that counts every call, read, and
write per slot (`vm.startStateDiffRecording`) and prices them with the Rootstock schedule. Sovryn and
LayerBank gave identical deltas.

| Path | Storage + calls | Logs | Rootstock total |
|---|---:|---:|---:|
| `withdrawToken` (lending) | −12,900 | −1,756 | **≈ −14,700** |
| `deleteDcaSchedule` (lending) | −12,900 | −1,756 | **≈ −14,700** |
| `withdrawAllAccumulatedInterest`, per pair | −11,100 | −1,756 | **≈ −12,900** |
| `withdrawTokenAndInterest` | −24,000 | −3,512 | **≈ −27,500** |

That is about 4 cents per exit at [R87](./R87-deferred-gas-candidates.md)'s conversion (1.0M
Rootstock gas ≈ $2.50 at 0.03 gwei). The implementation re-measures on this branch under both
profiles (**Measured pins**).

## Measured pins (2026-09-27)

These come from a throwaway harness (not shipped) on the MoC Sovryn and LayerBank lanes. It records
every call, read, and per-slot write with `vm.startStateDiffRecording`, on this branch and its parent
R96 (`1542177`), under both profiles. The two lanes and both profiles give the same storage and
call counts.

**Operations removed:**

| Path | Calls | Reads | Handler balance slot | Logs |
|---|---:|---:|---|---:|
| `withdrawToken` (lending) | −3 | −4 | `SET` + `CLEAR` removed | −1 |
| `deleteDcaSchedule` (lending) | −3 | −4 | `SET` + `CLEAR` removed | −1 |
| `withdrawAllAccumulatedInterest`, per pair | −1 | −2 | `SET` + `CLEAR` removed | −1 |
| `withdrawTokenAndInterest` | −4 | −6 | two `SET` + `CLEAR` pairs removed | −2 |

**Rootstock:**
- **Storage and calls:**
  - the `SET` + `CLEAR` round trip nets 10,000;
  - each call is 700;
  - each read is 200.
- **Logs:** each removed `Transfer` is 1,756 (375 + 3 × 375 topics + 8 × 32 data bytes).

| Path | Storage + calls | Logs | Rootstock total |
|---|---:|---:|---:|
| `withdrawToken` | −12,900 | −1,756 | **≈ −14,700** |
| `deleteDcaSchedule` | −12,900 | −1,756 | **≈ −14,800** |
| `withdrawAllAccumulatedInterest`, per pair | −11,100 | −1,756 | **≈ −12,900** |
| `withdrawTokenAndInterest` | −24,000 | −3,512 | **≈ −27,500** |

`deleteDcaSchedule` clears enough slots to hit Rootstock's `gasUsed / 2` refund cap on both sides.
Its saving is therefore half its gross reduction: 27,900 storage and calls, plus 1,756 of log, plus
compute. The lost 15,000 refund was never realized there.

**Foundry regression pins** (execution gas, Sovryn / LayerBank):

| Path | `default` | `deploy` (ships) |
|---|---:|---:|
| `withdrawToken` | −25,628 / −25,628 | −25,198 / −25,229 |
| `withdrawAllAccumulatedInterest` | −23,494 / −23,494 | −23,230 / −23,261 |
| `withdrawTokenAndInterest` | −49,122 / −49,122 | −48,428 / −48,490 |

**Runtime size under `deploy`:**
- `SovrynDocHandlerMoc` 8,344 → 8,037 (−307 B), and each Sovryn Dex leaf also −301 B.
- LayerBank MoC −321 B, Dex −319 B.
- The idle leaves, `DcaManager`, and `OperationsAdmin` are byte-identical: moving the transfer body
  into `IdleErc20Handler` changed nothing for idle.

**Behavior pin.** `RedeemToUserTest` fails on the parent on both lanes, because the stablecoin moves
market → handler → user, and passes here.

## Open product decisions

**none** (decided 2026-09-27).

## Scope

- [x] **Redeem hooks.** `LendingErc20Handler`:
  - `_protocolRedeem(uint256 sharesAmount, uint256 exchangeRate, address receiver)`;
  - `_measuredProtocolRedeem(..., address receiver)` measures `i_stableToken.balanceOf(receiver)`
    around the redeem;
  - `_redeemShares` keeps its signature. Only exits call it, so it always passes `user` as the
    receiver. The receipt-share check (invariant 11) is unchanged and still measures this
    handler's shares.
- [x] **Exits.** `withdrawInterest` and `_withdrawToken` redeem with `receiver = user`:
  - `withdrawInterest` drops its `safeTransfer` and the unreachable `if (stablecoinReceived > 0)`
    that guarded it;
  - `_withdrawToken` emits `TokenHandler__TokenWithdrawn(token, user, withdrawnAmount)` itself and
    no longer calls `super`.
- [x] **Batch.** `_batchRetrieveStablecoin` redeems with `receiver = address(this)`.
- [x] **Diagram.** `TokenHandler._withdrawToken` is declared without a body. `IdleErc20Handler`
      overrides it with the current transfer-and-measure body, measuring its own balance delta.
- [x] **Adapters.**
  - Sovryn: `i_iSusdToken.burn(receiver, sharesAmount)`.
  - LayerBank: `i_pool.withdraw(asset, amountOut, receiver)`.
  - Tropykus, which is test-only: `kToken.redeem` has no receiver, so when `receiver !=
    address(this)` it measures its own stablecoin delta and forwards it. The batch path reads
    nothing extra.
- [x] **Tests.**
  - The `LendingErc20HandlerRedeemTest` harness implements the new hook.
  - A new test pins that a lending exit never moves cash through the handler: no stablecoin
    `Transfer` to or from the handler on Sovryn and LayerBank. It also pins that the user's balance
    rises by the amount `TokenHandler__TokenWithdrawn` / `TokenLending__InterestWithdrawn` report.

## Out of scope

- [ ] A user-supplied `to` parameter. The receiver is always the calling user (invariant 3's spirit,
      and PR 22's excluded "withdrawal `to` parameter").
- [ ] Paying principal and interest from one redemption (R95 review item 5, rejected).
- [ ] Any change to idle withdrawals, deposits, events, errors, or the batch path.

## Files likely touched

- `src/LendingErc20Handler.sol`, `src/TokenHandler.sol`, `src/idle/IdleErc20Handler.sol`
- `src/sovryn/SovrynErc20Handler.sol`, `src/layerbank/LayerBankErc20Handler.sol`,
  `src/tropykus-legacy/TropykusErc20Handler.sol`
- `test/unit/LendingErc20HandlerRedeemTest.t.sol`, a new `test/unit/RedeemToUserTest.t.sol`
- `test/gas/R87IdleLedgerRemovalGas.t.sol`: its pre-R87 baseline harness inherited `TokenHandler`
  for the withdraw body, which has moved, so it now builds on `IdleErc20Handler`. It prices batch
  funding only, and that is unchanged.
- `AGENTS.md` (layout lines), `docs/relaunch/R97-redeem-lending-exits-to-user.md`, `README.md`,
  `IMPLEMENTATION_ORDER.md`, the R28 and R21 records

## Required tests

```text
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/RedeemToUserTest.t.sol -vv
make check
make fork-sovryn
make fork-tropykus
make fork-layerbank
```

The fork lanes are the real proof. Live iSUSD `burn(receiver, …)` and LayerBank `withdraw(…, to)` must
pay the user and burn exactly the debited shares. `make fork-layerbank` is added because LayerBank is
index 1 on both production maps.

## Success criteria

- [x] No lending exit writes the handler's stablecoin balance.
- [x] The batch path is unchanged.
- [x] `TokenHandler` has no `_withdrawToken` body; idle keeps today's behavior.
- [x] Rootstock deltas re-measured under both profiles and recorded.
- [x] `make check` and the three fork lanes green.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Invariant 1 (the user's balance is measured when paying the user) and invariant 11 (exact
      share consumption) hold.
- [ ] `TokenHandler__TokenWithdrawn` still reports measured cash paid to the user on every path.
- [ ] No relaunch ticket ids in `src/` comments.

## ABI / deploy / cutover impact

- ABI: none. Functions, events, and errors are unchanged.
- Scripts: none.
- Cutover: on lending exits, the stablecoin's `Transfer` log now goes from the market straight to the
  user instead of market → handler → user. `bitchill-monitoring` is checked for any rule keyed on the
  handler hop; an issue is opened only if one exists.
