# MoC `redeemFreeDoc` probe (R71)

Live Rootstock fork evidence that Money on Chain **immediate free-DOC redemption** stands alone.

Not part of `make check`, `make fork-*`, or CI (`test/mainnet-debug/**`). Needs `RSK_MAINNET_RPC_URL` in `.env`.

## Run

```bash
make probe-moc-redeem-free-doc
```

## What it proves

| Test | Claim |
|---|---|
| `test_redeemFreeDocAlonePaysRbtcWithoutPriorRequest` | Calling `redeemFreeDoc` **without** a prior `redeemDocRequest` spends DOC and pays native rBTC. |
| `test_redeemDocRequestDoesNotPayImmediateRbtc` | `redeemDocRequest` is the settlement-queue path: it does not pay immediate rBTC (success or revert both acceptable; rBTC delta must stay 0). |

BitChill purchases therefore call `redeemFreeDoc` only and let MoC revert data bubble. Zero measured rBTC still fails closed in `PurchaseRbtc`.

## Caveats

- MoC enforces a low `maxGasPrice`. The probe pins `tx.gasprice` to `20_000_000` wei (**0.02 gwei** — RSK prices run ~1000x below Ethereum norms) so Anvil's default does not false-fail with `"gas price is above the max allowed"`. On 2026-09-07 the proxy's `maxGasPrice()` was `30_300_000` wei (0.0303 gwei) and the network price 0.026 gwei; re-read it with `cast call <moc proxy> "maxGasPrice()(uint256)"` if the probe starts reverting.
- `DOC_HOLDER` must hold DOC on the tip you fork.
- This is evidence for the R71 source-phase MoC decision, not a substitute for `make fork-layerbank` purchase coverage.

## Addresses (RSK mainnet)

- MoC proxy: `0xf773B590aF754D597770937Fa8ea7AbDf2668370`
- DOC: `0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db`
