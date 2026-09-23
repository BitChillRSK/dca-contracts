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
branches on whether the **current** stored value is present (`oldValue == null`), not on an
original-value / dirty map:

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

### Cleared slots are deleted (why `null` means SET)

`doSSTORE`'s SET branch is `oldValue == null`, not `oldValue == 0`. That is load-bearing: if a
cleared slot stayed as an explicit zero in the trie, the next write would take the `else` path
(`RESET`, 5,000) instead of `SET` (20,000), and every clear-then-set analysis in this file — including
[R77](./R77-accumulated-rbtc-storage-sentinel.md)'s 15,000 swapper→user transfer — would invert.

It does not stay. [`MutableRepository.addStorageBytes`](https://github.com/rsksmart/rskj/blob/master/rskj-core/src/main/java/org/ethereum/db/MutableRepository.java)
passes `null` into the trie for an empty value, which removes the node (verified against current
`master`, 2026-09-19):

```java
// Special case: if the value is an empty vector, we pass "null" which commands the trie to remove the item.
if (value == null || value.length == 0) {
    internalPut(triekey, null);
}
```

A cleared slot is deleted, so the next write to it is a `SET` (20,000), not a `RESET` (5,000).

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

## Packed-field writes

A write to one field of a packed word compiles to a read, a mask, and an `SSTORE` of the whole word.
Solidity (legacy and via-IR alike) merges two such writes only when they are adjacent and nothing
that can revert, log, or call sits between them. A `SafeCast`, an `emit`, or a struct literal assigning
fields one by one is enough to keep them apart. The [audit](./ROOTSTOCK-GAS-AUDIT.md) measured a struct
literal writing one word five times.

On Cancun every write after the first to a dirty slot is ~100, so a Foundry diff shows the merge as
noise. On Rootstock each extra write is a full `RESET` (5,000). **Count `SSTORE`s per slot, not total
gas**: use `vm.startStateDiffRecording()` / `vm.stopAndReturnStateDiff()` and count the `isWrite`
storage accesses on each slot. To merge writes, do every cast and check first, write the fields back
to back, then emit.

## Account access: no EIP-2929 either

`GasCost.java` prices account access flat, with no cold/warm distinction:

| Opcode | Rootstock | Cancun cold / warm |
|---|---:|---:|
| `CALL` / `STATICCALL` / `DELEGATECALL` base | 700 | 2,600 / 100 |
| `BALANCE` | 400 | 2,600 / 100 |
| `EXTCODESIZE` / `EXTCODECOPY` | 700 | 2,600 / 100 |
| `EXTCODEHASH` | 400 | 2,600 / 100 |

The first call into a contract is cheaper on Rootstock than Foundry reports; every later call into
the same contract is about 7× dearer. Batching two reads of one contract into one call is worth more
than a Foundry diff suggests. Value transfer (`VT_CALL` 9,000) and new-account (`NEW_ACCT_CALL`
25,000) surcharges match Ethereum.

## Transient storage (Lovell 7.0.0)

`TLOAD` and `TSTORE` exist and cost 100 each (`GasCost.TLOAD` / `GasCost.TSTORE`). They were
activated by RSKIP-446 in Lovell 7.0.0 (mainnet block 7,338,024, 2025-03), together with `MCOPY`
(RSKIP-445). A per-transaction flag kept in transient storage therefore costs ~300 per round trip,
against ~10,200 for a non-zero storage flag written and restored (`SLOAD` + two `RESET`s). That makes
OZ `ReentrancyGuardTransient` the Rootstock-cheap guard; see [R82](./R82-transient-reentrancy-guard.md).

## Calldata: EIP-2028 adopted

`Transaction.java` charges 16 per non-zero and 4 per zero calldata byte once RSKIP-400 is active
(Arrowhead 6.0.0, mainnet block 6,223,700). This is the same as Ethereum, so calldata savings transfer
unchanged. Before Arrowhead, a non-zero byte cost 68.

## RSKIP watch list (draft, not active)

Neither proposal is active. If either activates, re-check every production gas claim that rests on
Petersburg-style SSTORE.

- [RSKIP-243](https://github.com/rsksmart/RSKIPs/blob/master/IPs/RSKIP243.md) (Draft, 2021) —
  per-transaction slot tracking and refund/net-metering changes. Breaks the
  `SET − REFUND = RESET` identity and every clear-vs-keep analysis that uses it (including R77).
- [RSKIP-244](https://github.com/rsksmart/RSKIPs/blob/master/IPs/RSKIP244.md) (Draft, 2021,
  Variable Storage Costs) — size-dependent SSTORE pricing that can put a non-zero→non-zero write
  well below today's flat `RESET` 5,000. Breaks the repeat-write conversion row and any estimate that
  assumes every in-tx rewrite still costs 5,000 (including R79-style packing claims).

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
| First write zero → non-zero (`SET`) | warm 20,000 / cold 22,100 | 20,000 | only when Foundry's slot was cold |
| First write non-zero → non-zero | warm 2,900 / cold 5,000 | 5,000 | only when Foundry's slot was cold |
| Repeat write to same slot in one tx | ~100 | 5,000 | no — Foundry 50× low |
| Clear-to-zero refund | 4,800 (EIP-3529) | 15,000 | no |
| Refund cap | `gasUsed / 5` | `gasUsed / 2` | no |
| Restore slot to its original value in the same tx | refunds most of the write (EIP-2200) | no refund; each write is 5,000 | no |
| First call into a contract in the tx | 2,600 | 700 | no — Foundry 3.7× high |
| Later call into the same contract | 100 | 700 | no — Foundry 7× low |
| `TLOAD` / `TSTORE` | 100 / 100 | 100 / 100 | yes |
| Calldata byte (non-zero / zero) | 16 / 4 | 16 / 4 | yes |

EIP-2929 footnote: Cancun charges `COLD_SLOAD_COST` (2,100) on the first access to a slot in
the transaction, then the warm SSTORE base (`SET` 20,000 or `SSTORE_RESET_GAS` 2,900). A cold
non-zero → non-zero write is therefore 2,100 + 2,900 = 5,000 — identical to Rootstock's flat
`RESET`. Do not convert a Foundry cold-RESET figure as if it were 2,900.

## How to use this file

1. Measure under Foundry when you need a **regression pin** or a same-build A/B (label it Foundry / Cancun).
2. For **production** operator or user economics on Rootstock, convert with the table above — or state
   the Rootstock constants (`SET` / `RESET` / `CLEAR` / `REFUND`) directly and do not quote Foundry
   cold-access deltas as Rootstock savings.
3. See `AGENTS.md` **Tests and done-gate** for the methodology rule.
