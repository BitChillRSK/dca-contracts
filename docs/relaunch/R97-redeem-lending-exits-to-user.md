# R97 — Redeem lending exits straight to the user

Status: **not started** · Assigned: yes · Optional/further-review: no · Stack on: R96

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

## Open product decisions

**none** (decided 2026-09-27).

## Scope

- [ ] **Redeem hooks.** `LendingErc20Handler`:
  - `_protocolRedeem(uint256 sharesAmount, uint256 exchangeRate, address receiver)`;
  - `_redeemShares(..., address receiver)`;
  - `_measuredProtocolRedeem(..., address receiver)` measures `i_stableToken.balanceOf(receiver)`
    around the redeem. The receipt-share check (invariant 11) is unchanged and still measures this
    handler's shares.
- [ ] **Exits.** `withdrawInterest` and `_withdrawToken` redeem with `receiver = user`:
  - `withdrawInterest` drops its `safeTransfer` and the unreachable `if (stablecoinReceived > 0)`
    that guarded it;
  - `_withdrawToken` emits `TokenHandler__TokenWithdrawn(token, user, withdrawnAmount)` itself and
    no longer calls `super`.
- [ ] **Batch.** `_batchRetrieveStablecoin` redeems with `receiver = address(this)`.
- [ ] **Diagram.** `TokenHandler._withdrawToken` is declared without a body. `IdleErc20Handler`
      overrides it with the current transfer-and-measure body, measuring its own balance delta.
- [ ] **Adapters.**
  - Sovryn: `i_iSusdToken.burn(receiver, sharesAmount)`.
  - LayerBank: `i_pool.withdraw(asset, amountOut, receiver)`.
  - Tropykus, which is test-only: `kToken.redeem` has no receiver, so it measures its own stablecoin
    delta and forwards it when `receiver != address(this)`.
- [ ] **Tests.**
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

- [ ] No lending exit writes the handler's stablecoin balance.
- [ ] The batch path is unchanged.
- [ ] `TokenHandler` has no `_withdrawToken` body; idle keeps today's behavior.
- [ ] Rootstock deltas re-measured under both profiles and recorded.
- [ ] `make check` and the three fork lanes green.

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
