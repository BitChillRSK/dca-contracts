# Sovryn SIP-0094 exit-fee probe

Live Rootstock fork checks for whether Sovryn's 0.1% Perimeter Fee (SIP-0094) is **charging** on iSUSD `burn`.

Not part of `make check`, `make fork-*`, or CI (`test/mainnet-debug/**`). Needs `RSK_MAINNET_RPC_URL` in `.env`.

## Run

```bash
make probe-sovryn-exit-fee
```

Full `burn` trace (look for a DOC `Transfer` to the ExitFeeVault, or a call to the controller):

```bash
make probe-sovryn-exit-fee PROBE_VERBOSITY=-vvvv
```

Controller flag only (no mint/burn):

```bash
make probe-sovryn-exit-fee PROBE_MATCH=test_controllerFlagAndVault
```

## How to read it

| Signal | Fee **off** (2026-08-19 tip) | Fee **on** at 10 bps |
|---|---|---|
| `exitFeeEnabled` | `false` | `true` |
| `burn returned` vs DOC received | equal (maybe 1–2 wei of `tokenPrice` rounding) | received ≈ 99.9% of returned |
| `ExitFeeVault DOC delta` | `0` | ~0.1% of the redemption |
| `-vvvv` trace | one DOC `Transfer` to the burner; no controller call | second `Transfer` to the vault; `ExitFeeApplied` |

A 0.1% fee on 1,000 DOC is **1 DOC**, not 1 wei. `sovrynProtocol.exitFeeController()` reverting `target not active` means Part 1's lending modules are not the live logic yet — the controller can exist while charging is still impossible.

## Addresses (RSK mainnet)

- iSUSD: `0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1`
- ExitFeeController: `0x8C1abf364Bf214E41221562693BD9Fb26D6Fa563`
- ExitFeeVault: `0x2ba389B021fA4A5F50cc1758EFD23Ca066d0Be08`
- sovrynProtocol: `0x5A0D867e0D70Fcc6Ade25C3F1B89d618b5B4Eaa7`
