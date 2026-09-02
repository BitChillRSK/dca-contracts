# R55 — Evaluate solx and the IR pipeline, then decide

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Decide, on measured evidence, whether BitChill compiles its relaunch bytecode with stock solc
(no IR), stock solc with `via_ir`, or solx. Produce a recommendation with numbers and a verification
result; **do not adopt anything in this PR**.

## Background

`solx` is an LLVM-based Solidity compiler that claims better gas and size than stock solc. The
question is worth asking now because the purchase path is protocol-paid and runs weekly per
schedule, so hot-path gas is a recurring cost rather than a one-off.

Two things must be settled before any solx number means anything.

**The baseline must be optimized.** Every gas figure recorded before [#104](https://github.com/BitChillRSK/dca-contracts/pull/104)
is unoptimized, and measuring solx against those numbers would credit it with wins that belong to
`optimizer = true`. R53 re-baselined the record and marks which figures are pre-#104 — see
[Measurement basis](./README.md#measurement-basis). Measured on the MoC/Sovryn lane:

| Config | `testSinglePurchase` | `testBatchPurchasesOneUser` |
| --- | --- | --- |
| optimizer off, no IR | 283,711 | 2,244,557 |
| optimizer on, no IR | 243,817 (−14.1%) | 1,562,720 (−30.4%) |
| optimizer on, via IR | 239,142 (−1.9% vs above) | 1,503,278 (−3.8% vs above) |

So solx is competing against ~239k, not ~284k. (R53's fresh run of the optimizer-on row at the R58 head:
243,790 and 1,562,441.) The headroom it must beat is what remains *after* the
optimizer and the IR pipeline have taken theirs.

**`via_ir` is not free today.** A full `forge build` under `via_ir = true` fails with solc error 1284
on `ZeroTokenPurchaseUniswap` (`test/unit/PurchaseUniswapSettingsTest.sol:440`): its constructor
reverts unconditionally by design — that *is* the test, proving a reversed inheritance list cannot
deploy — so the optimizer drops the immutable assignments while the runtime still reads them. Note
that `forge test --match-*` can mask this, because forge compiles sparsely and may never reach that
file. The `[profile.deploy]` that sidestepped it with `skip = ["test/**"]` no longer exists — #104 removed
it — so a deploy build under IR would need that skip re-created, and it would not help the test lanes
either way. Deciding whether and how to run tests under IR is part of this PR.

EIP-170 is explicitly **not** a motivation. With the optimizer on the margins are ~10.8 KB on `DcaManager` and
~8.9 KB on the Dex handlers (R53's fresh full build: 8,884–9,097 B — see
[Measurement basis](./README.md#measurement-basis)); nothing is size-constrained. Any past reasoning that reached for a
smaller compiler to fit a contract is void.

The counterweight is risk, and it is the deciding factor rather than a footnote. These contracts are
immutable, unproxied, and hold user funds; a miscompilation is unrecoverable. R23's toolchain proof
(Rootstock testnet acceptance plus Blockscout verification of `OperationsAdmin`, `DcaManager`, and a
handler) was obtained with stock solc, and a non-standard compiler puts that proof back on the table
— Blockscout must be able to verify what is actually deployed, on a chain that is not Ethereum
mainnet. A gas win that cannot be verified on the explorer is not shippable.

## Open product decisions

**none for the investigation.** The adoption decision is the *output* of this PR: present the
numbers, the verification result, and a recommendation, and let the human choose. Do not change the
compiler in this PR whatever the numbers say.

## Scope

- [ ] Install a pinned solx version; record the exact version and how it was obtained. Do not float.
- [ ] Establish the baseline at the settings [#104](https://github.com/BitChillRSK/dca-contracts/pull/104) pins (optimizer on, 200 runs, no IR). Every comparison
      is against this, never against the older unoptimized numbers.
- [ ] Measure four configurations — solc no-IR, solc via-IR, solx, and solx with whatever
      optimization level is its analogue — on:
      - runtime size for `DcaManager`, `OperationsAdmin`, `LayerBankErc20HandlerDex`,
        `SovrynErc20HandlerDex`;
      - `testSinglePurchase` and `testBatchPurchasesOneUser` on the MoC/Sovryn lane;
      - one Dex purchase and one deposit/withdraw pair, so the verdict is not read off a single test.
- [ ] Determine whether the full test matrix runs under each configuration, and what it would take
      to make `ZeroTokenPurchaseUniswap` compile under IR **without** weakening what it proves. Do
      not "repair" the contract by giving its constructor a reachable success path.
- [ ] Attempt a Rootstock testnet (chain 31) deploy and Blockscout verification for each candidate
      that clears the gas bar. Record tx hashes, or record precisely how verification fails.
- [ ] Report differential evidence, not just totals: for at least one purchase path, confirm the
      candidate and stock solc produce the same observable behavior across the full lane, and state
      plainly that identical test results are not a proof of equivalence.
- [ ] Recommend one option, with the residual risk named.

## Out of scope

- [ ] Changing `foundry.toml`, CI, or any deploy path. This PR measures and recommends only.
- [ ] Enabling the optimizer ([#104](https://github.com/BitChillRSK/dca-contracts/pull/104)) or correcting the recorded historical figures (R53).
- [ ] Any `src/` change to chase a compiler's numbers. If a candidate needs source changes to
      compile, that is a finding about the candidate.
- [ ] Reworking `_creditBuyers` or any other no-IR workaround. Those belong to the PRs that own them
      (R51 for `_creditBuyers`) once the pipeline is settled.

## Files likely touched

- `docs/relaunch/R55-solx-and-ir-evaluation.md` (the findings land in this spec)
- `docs/relaunch/IMPLEMENTATION_ORDER.md` (the recommendation and its rationale)
- Possibly a throwaway measurement script under `script/` or the scratchpad — not committed unless
  it is reusable and documented.

No `src/` file should change.

## Required tests

This item's "tests" are its measurements, and they must be reproducible:

- Full done-gate under each candidate that is a serious contender: `make check`, plus
  `make fork-sovryn` and `make fork-tropykus`.
- `make invariants-sovryn` specifically — the 64×512 stateful suite is the best available check that
  a different code generator has not changed behavior.
- Exact commands and environment for every number recorded, so a reviewer can re-run them.

## Success criteria

- [ ] A table comparing all four configurations on size and gas, against the optimized no-IR baseline.
- [ ] A clear statement of whether the full matrix passes under each.
- [ ] A Blockscout/Rootstock testnet verification result for each contender — success with tx
      hashes, or a specific failure mode.
- [ ] A recommendation naming the residual risk, with an explicit "keep stock solc" option that is
      chosen unless a candidate clears both the gas bar and verification.
- [ ] No compiler setting changed in this PR.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Every number is against the optimized no-IR baseline, never the unoptimized one.
- [ ] solx version is pinned and recorded.
- [ ] `ZeroTokenPurchaseUniswap` still proves that a reversed inheritance list cannot deploy.
- [ ] The recommendation weighs verification and miscompilation risk, not gas alone.
- [ ] No `src/` file changed.

## ABI / deploy / cutover impact

- ABI: none. Compiler choice does not move selectors, events, or storage layout — and if a candidate
  does move any of them, that is a blocking finding.
- Scripts: none in this PR.
- Cutover: none in this PR. Adopting a non-stock compiler later would change the verification story
  for every deployed contract and must re-prove R23's toolchain baseline.
