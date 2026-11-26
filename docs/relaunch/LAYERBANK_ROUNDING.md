# LayerBank share-exit rounding

This note separates deposit rounding, a handler's forfeited share, and a user's recoverable Pool residue.
The one-share forfeiture is specified in [R122](./R122-kann-lending-withdrawals.md).

## Units and assumptions

- `R = 10^27` is the liquidity-index scale. Let `I` be the index and `x = I / R`.
- The handler books **scaled aToken shares**. One scaled share represents `x` underlying base units before integer rounding.
- A stablecoin base unit is its smallest integer unit: `10^-18` DOC or USDRIF, or `10^-6` USDT0.
- A one-share limit is not a one-underlying-base-unit limit. Its underlying value changes with the index.
- The example uses the live half-up mint, transfer, and burn rules, with `I >= R`.
- Both deposits and both withdrawals occur at the same fork timestamp. No interest accrues between these test actions.
- The principal bound below applies to this two-deposit fixture. It does not cover arbitrary deposit histories or elapsed interest.

The fork lane checks the deployed burn and transfer rules in `LayerBankLivePoolProbe`.
The production adapter measures external share consumption and rejects a mismatched redemption.
An upgrade to different venue rounding requires a new review; see [the adapter's monitoring notes](../../src/layerbank/README.md#burn-rounding-assumption-and-monitoring).

## Exact example at Rootstock block 9443471

The fixture deposits 2,000 DOC twice. The total principal `P` is `4000000000000000000000` base units.
The index is `1017790042495147280571994120`, so `x = 1.01779004249514728057199412`.
The test also seeds an unrelated 200 DOC position directly in the user's wallet.
That position is excluded from BitChill's principal and remains unchanged in scaled units after both withdrawals.

| Step | Result |
| --- | --- |
| Ideal scaled shares per deposit | `1965041822473455566970.4943289323…` |
| Half-up minted shares per deposit | `1965041822473455566970` |
| Total booked shares `S` | `3930083644946911133940` |
| Exact mathematical underlying value `S × x` | `P - 1.0062461300924360237875672` |
| Underlying amount passed to aToken transfer: `floor(S × x)` | `P - 2` |
| Scaled shares actually transferred `M` | `3930083644946911133939`, or `S - 1` |
| Exact mathematical underlying value `M × x` | `P - 2.02403617258758330435956132` |
| First Pool withdrawal: `floor(M × x)` | `P - 3` cash base units |
| Scaled shares burned by that first withdrawal | `M - 1` |
| Scaled shares still owned by the user | `1` |
| Second Pool withdrawal | `1` additional cash base unit; burns the final received share |
| Final cash received | `P - 2` base units |
| Final user receipt balance | The same scaled balance as before the share exit |
| Handler remainder | One scaled share, deliberately unbooked |

Fractional values describe mathematical share value. Actual token transfers and balances use integer units.

The initial three-unit cash difference decomposes as follows:

```text
combined deposit rounding       1.00624613009243602378756720
one share retained by handler   1.01779004249514728057199412
first Pool withdrawal floor     0.97596382741241669564043868
                                --------------------------
initial cash difference         3.00000000000000000000000000
```

That initial cash difference is not entirely unrecoverable. The user still owns one receipt share.
The second withdrawal recovers one base unit and consumes that share.
The handler's forfeited share and the user's recoverable share are separate balances on separate addresses.

## Bound and exact accounting checks

For two half-up deposit mints at one index, let `S` be their combined minted shares and `P` their total principal.
Their combined share-value error satisfies `abs(S × x - P) <= x`.
The adapter's floored transfer moves either `S` or `S - 1` scaled shares under the supported transfer rules.
Therefore, for `M` received shares, `P - floor(M × x) <= ceil(2 × x)`.
The ceiling includes the final integer conversion. The bound is three underlying base units at this block.
Deposit rounding and the handler's permitted remainder are separate contributions to that bound.
The completed two-withdrawal sequence recovers any received-share residue and remains within the same conservative bound.

This bound does not replace exact assertions. `test_fork_layerBankWithdrawalThenRedeemAtPool` checks:

1. The handler loses exactly the scaled shares the user receives.
2. The handler forfeits at most one remaining share and clears the user's book and route balances.
3. Each requested Pool withdrawal pays exactly the measured stablecoin balance increase.
4. The first Pool withdrawal burns the predicted half-up scaled amount.
5. Any received-share residue is at most one share and remains on the user's address.
6. The second withdrawal consumes that residue. The deliberately seeded, nonzero pre-existing scaled balance remains intact.
7. The user's direct Pool withdrawals change neither the handler's share balance nor its stablecoin balance.

Other tests reject excessive or zero handler share consumption, preserve larger remainders, and isolate other users and routes.
The stateful suite reconciles booked shares, forfeited shares, and external receipt shares separately.

## Consequences

Rounding is deterministic for a given amount and index; how often a one-share remainder occurs has not
been measured.

The handler's one-share forfeiture is an accepted accounting tradeoff, not a recovered payment.
[R122](./R122-kann-lending-withdrawals.md) gives the reason for it.
A larger remainder remains booked. The handler adds no second transfer, owner sweep, or compensation from pooled user funds.
One-share forfeitures can accumulate across exits; this is not a global one-share cap.
Likewise, mint-rounding error can accumulate across deposits. The two-deposit tolerance must not become a universal principal guarantee.

The user-owned Pool residue is expected after a withdrawal sized by a floored underlying conversion.
It remains the user's property and needs no change to BitChill's books.
A share-aware full redemption can avoid the second user transaction. For this index, requesting `P - 2` initially burns all `M` received shares.
The adapter already uses exact-burn sizing for redemptions that BitChill itself executes.
The share-exit path transfers receipt tokens and intentionally makes no Pool cash withdrawal, so it remains useful when the venue cannot redeem.

An exact-share transfer sized for the current half-up rule could avoid the handler's one-share remainder.
That sizing would add a dependency on the transfer rounding rule. The current floored transfer stays within the booked shares under both half-up and round-up rules.
A change to exact-share transfer sizing therefore needs a separate review of exit availability after a venue upgrade.

## Replay

Load `RSK_MAINNET_RPC_URL` from the local environment without printing it. Do not broadcast transactions.
These commands execute against a local fork:

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC forge test --match-contract LendingShareWithdrawalTest --fork-block-number 9443471 --fork-url "$RSK_MAINNET_RPC_URL"
FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC forge test --match-contract LendingShareWithdrawalTest --fork-block-number 9443471 --fork-url "$RSK_MAINNET_RPC_URL"
```

Omit `--fork-block-number 9443471` to exercise the same checks at the chain tip.
The pinned example's exact values belong to DOC at that block; they are not constants for the other markets.
