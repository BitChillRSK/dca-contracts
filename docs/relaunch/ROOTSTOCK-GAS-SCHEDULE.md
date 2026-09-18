# Rootstock gas schedule (vs Foundry / Cancun)

Durable reference for converting Foundry gas figures to what Rootstock (`rskj`) actually charges.
Foundry/`revm` prices execution like Ethereum Cancun. Rootstock does not. Specs and PR bodies that
talk about production operator or user gas must say which schedule each number is on.

## Storage access: no EIP-2929

[`GasCost.java`](https://github.com/rsksmart/rskj/blob/master/rskj-core/src/main/java/org/ethereum/vm/GasCost.java)
defines `SLOAD = 200` as a flat constant. There are no cold/warm access constants and no cold-access
surcharge. Every `SLOAD` costs 200 gas.

## SSTORE: no EIP-1283 / EIP-2200 net metering

[`VM.java` `doSSTORE`](https://github.com/rsksmart/rskj/blob/master/rskj-core/src/main/java/org/ethereum/vm/VM.java)
branches only on whether the **current** stored value is zero. There is no original-value / dirty map:

```java
// From null to non-zero
if (oldValue == null && !newValue.isZero()) {
    gasCost = GasCost.SET_SSTORE;
}
// from non-zero to zero
else if (oldValue != null && newValue.isZero()) {
    program.futureRefundGas(GasCost.REFUND_SSTORE);
    gasCost = GasCost.CLEAR_SSTORE;
} else
// from zero to zero, or from non-zero to non-zero
{
    gasCost = GasCost.RESET_SSTORE;
}
```

Consequence: every write to a non-zero slot costs `RESET_SSTORE` (5,000), including repeat writes to
the same slot inside one transaction. Foundry's warm repeat-write (~100) does not apply.

## Pre-EIP-3529 refunds

From the same `GasCost.java`:

| Constant | Value |
|---|---:|
| `SET_SSTORE` | 20,000 |
| `RESET_SSTORE` | 5,000 |
| `CLEAR_SSTORE` | 5,000 |
| `REFUND_SSTORE` | 15,000 |

Ethereum's [EIP-3529](https://eips.ethereum.org/EIPS/eip-3529) reduced the clear refund to 4,800 and
capped refunds at `gasUsed / 5`. Rootstock never adopted that cut.

### Identity that kills a family of “keep the slot warm” optimizations

```
SET − REFUND = 20,000 − 15,000 = 5,000 = RESET
```

On Rootstock, keeping a slot non-zero instead of clearing and re-setting is **gas-neutral by
construction** for the pair (clear+set) vs (reset). Storage sentinels, seeded balances, and retained
allowances create **zero net system gas value** there. They can still move cost between parties (see
[R77](./R77-accumulated-rbtc-storage-sentinel.md)): the swapper avoids a SET; the user forgoes a clear
refund.

### Refund cap (verified)

[`TransactionExecutor.java`](https://github.com/rsksmart/rskj/blob/master/rskj-core/src/main/java/org/ethereum/core/TransactionExecutor.java)
applies:

```java
long gasRefund = Math.min(result.getFutureRefund(), result.getGasUsed() / 2);
```

So the cap is **`gasUsed / 2`** (Ethereum's pre-3529 rule), not `/ 5`. A full `REFUND_SSTORE` of 15,000
is fully realized whenever the transaction's `gasUsed` before refund is at least 30,000 — true of any
real BitChill rBTC withdrawal.

## RSKIP-243 (watch item)

[RSKIP-243](https://github.com/rsksmart/RSKIPs/blob/master/IPs/RSKIP243.md) (Draft, 2021) would introduce
per-transaction slot tracking and change SSTORE / refund accounting. It is **not** active. If it
activates, the net-metering conclusions in this file change and every production gas claim that rests
on Petersburg-style SSTORE must be re-checked.

## Corroboration from this repo

[R64-batch-calldata-and-schedule-keying.md](./R64-batch-calldata-and-schedule-keying.md) (§ “What
Rootstock charged”, around the live replay note) recorded tx `0xa6ac747a…` at **815,384** gas on
Rootstock against a Foundry replay of identical state at **923,984** — **13.3% high**, and named
“storage-access pricing” as an untested guess for the gap. **That open question is closed here:**
Foundry was applying EIP-2929 cold SLOAD/SSTORE surcharges that rskj does not charge. The direction
and magnitude match a storage-heavy tick priced on Cancun access lists.

## Conversion table

| Component | Foundry (Cancun) | Rootstock | Transfers? |
|---|---:|---:|---|
| Compute, memory, stack | same | same | yes |
| LOG (375 base / 375 per topic / 8 per byte) | same | same | yes |
| First `SLOAD` of a slot | 2,100 | 200 | no — Foundry 10.5× high |
| Repeat `SLOAD` | 100 | 200 | no — Foundry understated |
| First write zero → non-zero (`SET`) | ~22,100 cold | 20,000 | approximate only |
| First write non-zero → non-zero | ~2,900 cold | 5,000 | no |
| Repeat write to same slot in one tx | ~100 | 5,000 | no — Foundry 50× low |
| Clear-to-zero refund | 4,800 (EIP-3529) | 15,000 | no |
| Refund cap | `gasUsed / 5` | `gasUsed / 2` | no |

## How to use this file

1. Measure under Foundry when you need a **regression pin** or a same-build A/B (label it Foundry / Cancun).
2. For **production** operator or user economics on Rootstock, convert with the table above — or state
   the Rootstock constants (`SET` / `RESET` / `CLEAR` / `REFUND`) directly and do not quote Foundry
   cold-access deltas as Rootstock savings.
3. See `AGENTS.md` **Tests and done-gate** for the methodology rule.
