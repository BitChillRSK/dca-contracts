# Sovryn SIP-0094 exit-fee probe

Live Rootstock fork checks for whether Sovryn's 0.1% Perimeter Fee (SIP-0094) is **charging** on iSUSD `burn`.

Not part of `make check`, `make fork-*`, or CI (`test/mainnet-debug/**`). Needs `RSK_MAINNET_RPC_URL` in `.env`.

## Run

```bash
make probe-sovryn-exit-fee
```

Full `burn` trace (look for the DOC `Transfer` of the haircut):

```bash
make probe-sovryn-exit-fee PROBE_VERBOSITY=-vvvv
```

Controller / sink balances only (no mint/burn):

```bash
make probe-sovryn-exit-fee PROBE_MATCH=test_controllerFlagAndVault
```

## How to read it

**Primary signal is gross vs net.** `burn`'s return is GROSS; DOC credited to the burner is NET. A ~10 bps gap means the fee is live, regardless of `exitFeeEnabled`.

| Signal | Fee **off** | Fee **on** at 10 bps (tip ≥ ~9,219,745, observed 2026-09-07) |
|---|---|---|
| `burn returned` vs DOC received | equal (maybe 1–2 wei of `tokenPrice` rounding) | received ≈ 99.9% of returned |
| `live fee sink DOC delta` | `0` | ~0.1% of the redemption |
| `legacy ExitFeeVault DOC delta` | `0` | **stays `0` on tip** — do not treat as the canary |
| `exitFeeEnabled` / `feeReceiver` | historically matched | **stale on tip** (`false` / old vault while fee still charges) |
| `-vvvv` trace | one DOC `Transfer` to the burner | second `Transfer` to `LIVE_FEE_SINK` |

A 0.1% fee on 1,000 DOC is **1 DOC**, not 1 wei.

## Live economics record (durable)

Observed on Rootstock mainnet while preparing R71 (#128), 2026-09-07:

| Block | Haircut on iSUSD `burn` |
|---|---|
| 8,900,000 | 0 bps |
| 9,100,000 | 0 bps |
| 9,200,000 | 0 bps |
| ~9,219,745 (tip that day) | **10 bps** |

Haircut destination on tip burns: `0xDDE75f75ff33Aa802f2316cCAe2bE77823fc6f9B` (`LIVE_FEE_SINK` in the probe).

Historical addresses that **no longer** receive the tip fee (kept for archaeology; reading them alone false-negatives):

- ExitFeeController: `0x8C1abf364Bf214E41221562693BD9Fb26D6Fa563` (`exitFeeEnabled` still `false` while fee charges)
- Legacy ExitFeeVault / early `feeReceiver`: `0x2ba389B021fA4A5F50cc1758EFD23Ca066d0Be08`

BitChill contracts already measure cash (R1 / R20 / NetRedemptionTest). This probe is the early-warning instrument for **when** live Sovryn economics changed — not a substitute for balance-delta accounting.

## Addresses (RSK mainnet)

- iSUSD: `0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1`
- DOC: `0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db`
- Live fee sink (tip): `0xDDE75f75ff33Aa802f2316cCAe2bE77823fc6f9B`
- ExitFeeController (views may be stale): `0x8C1abf364Bf214E41221562693BD9Fb26D6Fa563`
- Legacy ExitFeeVault: `0x2ba389B021fA4A5F50cc1758EFD23Ca066d0Be08`
- sovrynProtocol: `0x5A0D867e0D70Fcc6Ade25C3F1B89d618b5B4Eaa7`
