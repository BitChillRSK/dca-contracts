# R55 — Evaluate solx and the IR pipeline, then decide

Status: **measured; recommendation is keep stock solc, no IR** · Assigned: PR 58 ([#113](https://github.com/BitChillRSK/dca-contracts/pull/113)) · Optional/further-review: no · Order: after R59

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

- [x] Install a pinned solx version; record the exact version and how it was obtained. Do not float.
- [x] Establish the baseline at the settings [#104](https://github.com/BitChillRSK/dca-contracts/pull/104) pins (optimizer on, 200 runs, no IR). Every comparison
      is against this, never against the older unoptimized numbers.
- [x] Measure four configurations — solc no-IR, solc via-IR, solx, and solx with whatever
      optimization level is its analogue — on:
      - runtime size for `DcaManager`, `OperationsAdmin`, `LayerBankErc20HandlerDex`,
        `SovrynErc20HandlerDex`;
      - `testSinglePurchase` and `testBatchPurchasesOneUser` on the MoC/Sovryn lane;
      - one Dex purchase and one deposit/withdraw pair, so the verdict is not read off a single test.
- [x] Determine whether the full test matrix runs under each configuration, and what it would take
      to make `ZeroTokenPurchaseUniswap` compile under IR **without** weakening what it proves. Do
      not "repair" the contract by giving its constructor a reachable success path.
- [ ] Attempt a Rootstock testnet (chain 31) deploy and Blockscout verification for each candidate
      that clears the gas bar. Record tx hashes, or record precisely how verification fails.
- [x] Report differential evidence, not just totals: for at least one purchase path, confirm the
      candidate and stock solc produce the same observable behavior across the full lane, and state
      plainly that identical test results are not a proof of equivalence.
- [x] Recommend one option, with the residual risk named.

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

- [x] A table comparing all four configurations on size and gas, against the optimized no-IR baseline.
- [x] A clear statement of whether the full matrix passes under each.
- [x] A Blockscout/Rootstock testnet verification result for each contender — success with tx
      hashes, or a specific failure mode.
- [x] A recommendation naming the residual risk, with an explicit "keep stock solc" option that is
      chosen unless a candidate clears both the gas bar and verification.
- [x] No compiler setting changed in this PR.

## Reviewer checklist

- [x] Matches **Scope**; nothing from **Out of scope**.
- [x] Every number is against the optimized no-IR baseline, never the unoptimized one.
- [x] solx version is pinned and recorded.
- [x] `ZeroTokenPurchaseUniswap` still proves that a reversed inheritance list cannot deploy.
- [x] The recommendation weighs verification and miscompilation risk, not gas alone.
- [x] No `src/` file changed.

## ABI / deploy / cutover impact

- ABI: none. Compiler choice does not move selectors, events, or storage layout — and if a candidate
  does move any of them, that is a blocking finding.
- Scripts: none in this PR.
- Cutover: none in this PR. Adopting a non-stock compiler later would change the verification story
  for every deployed contract and must re-prove R23's toolchain baseline.

---

# Findings (measured 2026-09-03)

## Recommendation

**Keep stock solc, no IR** — the settings [#104](https://github.com/BitChillRSK/dca-contracts/pull/104)
pins (`0.8.36`, `cancun`, `optimizer = true`, `optimizer_runs = 200`, `via_ir = false`). Neither
candidate clears the bar the spec set, and one of them cannot compile this repository at all.

- **solx wins the gas contest and loses everything else.** It is the fastest of the four on every
  measurement (−6.8% on the `batchBuyRbtc` call itself, −8.9% on `testSinglePurchase`), and the full
  lane matrix passes under it with test-for-test identical results. But solx v0.1.8's Solidity front
  end is `0.8.34`, and every first-party file here pins `pragma solidity 0.8.36;`, so **solx cannot
  compile `src/` as written**. Adopting it means downgrading 143 pragmas — an `src/` change the spec
  puts out of scope — and re-proving R23's toolchain baseline at a lower solc. On top of that its own
  README says the project "is in beta and must be used with caution. Please use it only for testing
  and experimentation", and Rootstock's Blockscout cannot verify what it emits (below).
- **`via_ir` is a real but small win that costs test work.** −2.6% on `batchBuyRbtc`, −2.0/−4.2% on
  the two hot-path tests, and ~20–26% smaller runtime, all with stock solc, so the verification story
  is unchanged. It does not pay for itself before relaunch: two test files fail to compile under it,
  and a third behaviour (a `block.timestamp` cached across `vm.warp`) changes, which is a harness
  hazard rather than a production one but has to be understood and fixed by hand.

Sizes are recorded for completeness and are **not** an argument either way — EIP-170 margins are
8.1–10.0 KB at the R59 head, exactly as the spec says.

## Environment and pins

| Item | Value |
| --- | --- |
| Machine | macOS 25.6 (darwin, arm64), same host for every number |
| Foundry | `forge 1.5.1-stable` (`b0a9dd9`, maxperf) |
| Repo head | `260d7ef` (R59 stack head, this PR's base) |
| Compiler settings | `evm_version = cancun`, `optimizer = true`, `optimizer_runs = 200` everywhere |
| solx | **v0.1.8**, released 2026-08-20 by NomicFoundation (the project moved from Matter Labs) |
| solx asset | `solx-macosx-v0.1.8`, sha256 `5eda882c060d88b113876e91078ee35471f95e33772679732e339902a3dd4ec2` (matches the published `.sha256`) |
| solx front end | `0.8.34+commit.91fef221` — **not** upstream solc, which is `0.8.34+commit.80d5c536` |

Foundry 1.5.1 has no solx integration (`strings $(which forge) | grep -c solx` → 0); solx was driven
through `forge --use <path>`, which works because solx accepts solc's `--standard-json`. Forge then
labels it `Solc 0.8.34` in build output, so **nothing in a build log distinguishes solx from stock
solc** — an operational hazard in its own right.

### The 0.8.34 control

solx cannot compile `pragma solidity 0.8.36;`:

```
Error: ParserError: Source file requires different compiler version
(current compiler is 0.8.34+commit.91fef221.Darwin.appleclang)
```

So the solx columns were measured on a throwaway copy of `src/`, `script/`, `test/` and `lib/` in the
scratchpad with all 143 pragmas and `solc_version` rewritten `0.8.36` → `0.8.34`. **That copy was then
compiled with stock solc 0.8.34 as a control**, and it reproduces the baseline exactly — same runtime
byte counts on every contract measured and the same gas to the unit on all five gas figures. The solx
deltas below are therefore solx's, not the front-end version's. No repo file was changed for any of
this; the copy is scratchpad-only and is not part of the diff.

## Runtime size (bytes)

| Contract | solc no-IR (baseline) | solc via-IR | solx -O3 | solx -Oz |
| --- | ---: | ---: | ---: | ---: |
| `DcaManager` | 14,542 | 11,712 (−19.5%) | 13,785 (−5.2%) | 11,158 (−23.3%) |
| `OperationsAdmin` | 3,227 | 2,568 (−20.4%) | 2,400 (−25.6%) | 2,371 (−26.5%) |
| `LayerBankErc20HandlerDex` | 16,483 | 12,858 (−22.0%) | 14,568 (−11.6%) | 12,655 (−23.2%) |
| `SovrynErc20HandlerDex` | 16,270 | 12,583 (−22.7%) | 14,272 (−12.3%) | 12,480 (−23.3%) |
| `TropykusErc20HandlerDex` | 16,414 | 12,722 (−22.5%) | 14,321 (−12.8%) | 12,642 (−23.0%) |
| `IdleDocHandlerMoc` | 7,539 | 5,603 (−25.7%) | 5,552 (−26.4%) | 5,311 (−29.6%) |
| `SovrynDocHandlerMoc` | 10,871 | 8,389 (−22.8%) | 9,025 (−17.0%) | 8,017 (−26.3%) |
| `LayerBankDocHandlerMoc` | 11,095 | 8,631 (−22.2%) | 9,331 (−15.9%) | 8,203 (−26.1%) |

`-O3` is what `forge --use solx` produces by default: the CLI at `-O3` reproduces the forge-driven
sizes byte for byte. `-Oz` is solx's size analogue and needed a wrapper (below) because foundry has no
way to set solx's `-O` level.

## Gas

MoC/Sovryn lane unless noted (`SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC`).
Percentages are against the baseline column.

| Measurement | solc no-IR | solc via-IR | solx -O3 | solx -Oz |
| --- | ---: | ---: | ---: | ---: |
| `DcaManager.batchBuyRbtc` (gas report, contract-side) | 202,530 | 197,205 (−2.6%) | 188,806 (−6.8%) | 191,317 (−5.5%) |
| `testSinglePurchase` | 243,837 | 238,969 (−2.0%) | 222,031 (−8.9%) | 225,494 (−7.5%) |
| `testBatchPurchasesOneUser` | 1,563,383 | 1,497,224 (−4.2%) | 1,283,361 (−17.9%) | 1,330,968 (−14.9%) |
| `testStablecoinDeposit` | 150,452 | 147,296 (−2.1%) | 138,684 (−7.8%) | 140,223 (−6.8%) |
| `testStablecoinWithdrawal` | 101,852 | 99,558 (−2.3%) | 93,069 (−8.6%) | 94,103 (−7.6%) |
| `testSinglePurchase`, Dex lane (LayerBank / USDRIF) | 338,362 | 334,004 (−1.3%) | 313,026 (−7.5%) | 317,518 (−6.2%) |

The first row is the one that matters for the protocol's recurring cost: it is the call itself, with
the test contract's own code excluded. The whole-test rows move more because they also compile the
harness with the candidate compiler; do not read the batch row's −17.9% as a −17.9% saving on the
bot's bill.

**What the win is worth.** On the basis this repo has used elsewhere (~2,300 gas ≈ 1.4 US cents on
Rootstock), the per-purchase saving on `batchBuyRbtc` is ~3.2 cents under `via_ir` and ~8.4 cents
under solx. At a thousand weekly purchases that is roughly $32 and $84 a week. Real, and still small
against re-proving that immutable, fund-holding bytecode was compiled correctly.

Build time on the same host, full tree, cold cache: stock solc **27 s**, solx -O3 **45 s**,
`via_ir` **~180 s**.

## Does the full matrix run?

The matrix is the seven `make check` lanes: `moc-none`, `moc-layerbank`, `moc-sovryn`,
`STABLECOIN_TYPE=USDRIF dex-sovryn`, `STABLECOIN_TYPE=USDRIF dex-layerbank`,
`STABLECOIN_TYPE=USDT0 dex-layerbank`, and `invariants-sovryn` (64 × 512).

| Config | Result |
| --- | --- |
| solc no-IR | Yes — `make check` passes at this head (the done-gate for this PR). |
| solc via-IR | **No.** Two files do not compile; with both skipped, one test then fails. |
| solx -O3 | Yes — all seven lanes, `801 / 805 / 815 / 469 / 786 / 786` passed and 0 failed, plus 11 invariants at 32,768 calls each. |
| solx -Oz | Yes — identical counts to -O3 and to the 0.8.34 control, lane for lane. |

The solx and control runs are the differential evidence the spec asked for: same tree, same tests,
same lanes, two different code generators, **identical pass/skip counts and zero failures**, including
the stateful suite. That is the strongest routine check available here, and it is still not a proof of
equivalence — it says no test distinguished the two, not that no input can.

### The two `via_ir` compile failures

1. `test/unit/PurchaseUniswapSettingsTest.sol` — `ZeroTokenPurchaseUniswap`, solc error 1284,
   "Some immutables were read from but never assigned, possibly because of optimization." Known and
   predicted by this spec. The constructor always reverts by design; that is what the test proves.
2. `test/unit/RbtcWithdrawalTest.t.sol` — **not previously recorded.** Yul stack-too-deep
   (`Variable size_19 is 1 too deep in the stack`, `memoryguard was present`) in the shared harness
   function `DcaDappTest.makeSeveralPurchasesWithSeveralSchedules`, which only this file pulls in.
   `via_ir` is usually the *cure* for stack-too-deep; here it is the cause, and the optimizer at 200
   runs does not clear it. Fixing it means restructuring a harness function, not a compiler flag.

`forge test --match-*` hides both, because forge compiles sparsely and neither file is reached by the
narrow runs used for the gas table. Only a full `forge build` or an unfiltered `forge test` shows them.

**What it would take to compile (1) under IR without weakening it.** Foundry 1.5.1 can do this without
touching the contract, via a second compiler profile and a path restriction:

```toml
[[profile.default.additional_compiler_profiles]]
name = "legacy-codegen"
via_ir = false
optimizer = true            # required: the extra profile does not inherit the default's optimizer,
optimizer_runs = 200        # and without it the build fails stack-too-deep under legacy codegen

[[profile.default.compilation_restrictions]]
paths = "test/unit/PurchaseUniswapSettingsTest.sol"
via_ir = false
```

That builds, and `ZeroTokenPurchaseUniswap` keeps its always-reverting constructor and its `pure`
`_purchaseToken()` override — nothing about what it proves changes. The cost is that the restriction
propagates to the file's whole import graph: every production contract is then compiled **twice**
(`DcaManager` 11,712 B via IR and `DcaManager.legacy-codegen` 14,542 B), and the restricted test
exercises the legacy bytecode while production would ship the IR bytecode. A test that proves a
deployment guard against a different code generator than the one deployed is worth less than it looks.
There is a trap here too: run this with a warm cache and it "succeeds" while quietly serving cached
legacy artifacts for everything — the tell is that the sizes come out equal to the no-IR baseline.

### The `via_ir` behaviour change

With both files skipped, six of the seven lanes still fail one test:
`RbtcPurchaseTest.testLastPurchaseTimestampConsistencyWhenScheduleResumed(uint256)`, counterexample
`3582983`. It reduces to five lines that have nothing to do with this protocol:

```solidity
function testCachedTimestampSurvivesWarp() public {
    uint256 cached = block.timestamp;   // 1
    vm.warp(block.timestamp + 3582983);
    assertEq(cached, 1);                // legacy: passes. via_ir: cached reads back as 3582984.
}
```

Under IR the Yul optimizer rematerialises `TIMESTAMP` instead of keeping the local, which is a valid
transformation on chain — inside one transaction `block.timestamp` cannot change — and wrong the
moment a cheatcode moves the clock. So this is a **test-harness hazard, not a production
miscompilation**: no user transaction can observe it. It still means adopting IR requires auditing
every test that caches a block value across `vm.warp` / `vm.roll`, and it is a good illustration of
why "the suite is green" is weak evidence about a code generator.

The stateful invariant suite passes under IR (11 invariants, 64 × 512).

## Verification on Rootstock

This is where solx fails outright, and it did not need a deploy to establish.

- Every solx artifact carries `solx:0.1.8;solc:0.8.34` in its CBOR metadata (`dsolcx.solx:0.1.8;solc:0.8.34`
  in the runtime tail of `DcaManager`, `SovrynErc20HandlerDex` and `OperationsAdmin`).
- solx's front end is a **fork** of solc — it reports `0.8.34+commit.91fef221`, where upstream 0.8.34
  is `0.8.34+commit.80d5c536` (binaries.soliditylang.org). No stock solc reproduces solx bytecode.
- Rootstock's explorers are Blockscout, and their verifier advertises only Solidity and Vyper:
  `GET /api/v2/smart-contracts/verification/config` on both
  `rootstock-testnet.blockscout.com` and `rootstock.blockscout.com` returns
  `solidity_compiler_versions` and `vyper_compiler_versions` and nothing else — no solx or other
  alternative-compiler list. The Solidity list contains `v0.8.36+commit.8a079791` and
  `v0.8.34+commit.80d5c536` (both upstream, and `cancun` is among the EVM versions), so **stock**
  solc verification is available for exactly what R23 proved, and there is no version entry a
  solx-compiled contract could match. Verification options are `standard-input`, `multi-part`,
  `flattened-code` and `sourcify`; all recompile from source with stock solc.

So a solx deployment would be an unverifiable contract holding user funds. Per the spec's own bar, a
gas win that cannot be verified is not shippable, and the question stops there.

`via_ir` has no such problem: it is stock solc, and `standard-input` verification carries
`settings.viaIR` through to the recompile. R23's proof was obtained under legacy codegen, so adopting
IR would still want one fresh testnet deploy + verification to re-prove the baseline — that is a small,
concrete cost, not an unknown.

**The testnet deploy in Scope was not performed**, and the box above is left unticked. Three reasons,
in order: `AGENTS.md` forbids `--broadcast` and talking to live contracts from this repo's agent work;
the only candidate whose verification story was in doubt (solx) cannot compile the tree at `0.8.36`,
so any deploy would have been of pragma-downgraded sources that differ from what the repo reviews; and
the explorer's own verifier configuration answers the question the deploy was meant to answer. If the
human wants the on-chain confirmation anyway, the cheap version is: deploy `OperationsAdmin` (2.4–3.2 KB,
no constructor dependencies) to chain 31 and try `forge verify-contract --verifier blockscout` for each
candidate. Expect stock solc and `via_ir` to verify, and solx to fail on compiler version.

## Other checks

- **ABI and storage layout are unchanged by the compiler.** `DcaManager`, `OperationsAdmin` and
  `SovrynErc20HandlerDex` produce byte-identical ABI JSON under solc and solx, and `forge inspect
  storage-layout` matches on `DcaManager` (5 entries) and `SovrynErc20HandlerDex` (15). The spec's
  blocking finding does not fire.
- **R51's `_creditBuyers` shape stays as it is.** R53 recorded that only `via_ir` would reopen it;
  this PR recommends against `via_ir`, so nothing reopens.

## Residual risk of the recommendation

Keeping stock solc no-IR leaves the recurring purchase cost ~2.6% (via IR) to ~6.8% (solx) above the
cheapest measured option, forever, on a protocol-paid path. That is the price of the choice and it is
the whole downside. Against it: R23's testnet + Blockscout proof stays valid, the deployed bytecode
stays reproducible by anyone with upstream solc, no test is restructured to satisfy a code generator,
and the pipeline that produced every audited number stays the pipeline that ships.

## When to revisit

Reopen this only when all three hold, and re-measure rather than trusting these numbers:

1. solx ships a front end at or above the repo's pinned solc (0.8.36 today) so no pragma changes;
2. solx is out of beta, or the team is willing to sponsor an audit of the emitted bytecode;
3. an explorer Rootstock actually runs can verify solx output.

`via_ir` can be reconsidered on its own at any point after relaunch, when a test-harness change is
cheap: the work is (1) a compiler-profile restriction or an equivalent for `ZeroTokenPurchaseUniswap`,
(2) restructuring `makeSeveralPurchasesWithSeveralSchedules`, (3) auditing timestamp caching across
cheatcode warps, and (4) one testnet deploy + verification to re-prove R23 under IR.

## Reproducing every number

All of it runs from a clean checkout at `260d7ef` plus a scratchpad copy; nothing below writes to the
repo except into gitignored `out/` and `cache/`.

```bash
# Baseline sizes and gas (repo, stock settings)
forge build --sizes --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["DcaManager"]["runtime_size"])'
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/RbtcPurchaseTest.t.sol \
    --match-test "testSinglePurchase|testBatchPurchasesOneUser" -j 1 --gas-report

# via_ir: full build fails, and shows both blockers one after the other
FOUNDRY_VIA_IR=true FOUNDRY_OUT=/tmp/out-ir FOUNDRY_CACHE_PATH=/tmp/cache-ir forge build           # error 1284
FOUNDRY_VIA_IR=true FOUNDRY_OUT=/tmp/out-ir FOUNDRY_CACHE_PATH=/tmp/cache-ir \
  forge build --skip PurchaseUniswapSettingsTest.sol                                               # stack too deep
# via_ir sizes (src only) and gas
FOUNDRY_VIA_IR=true FOUNDRY_OUT=/tmp/out-ir2 FOUNDRY_CACHE_PATH=/tmp/cache-ir2 forge build --sizes --skip "test/**"
FOUNDRY_VIA_IR=true FOUNDRY_OUT=/tmp/out-ir3 FOUNDRY_CACHE_PATH=/tmp/cache-ir3 \
  SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/RbtcPurchaseTest.t.sol --match-test testSinglePurchase -j 1 --gas-report

# solx: pin it, check it, and note it cannot compile 0.8.36
curl -sSL -o solx https://github.com/NomicFoundation/solx/releases/download/0.1.8/solx-macosx-v0.1.8
shasum -a 256 solx      # 5eda882c060d88b113876e91078ee35471f95e33772679732e339902a3dd4ec2
chmod +x solx && ./solx --version

# solx measurements run on a scratchpad copy with pragmas rewritten to 0.8.34:
#   cp -R src script test lib foundry.toml <copy>/ && find <copy>/{src,script,test} -name '*.sol' \
#     -exec sed -i '' 's/pragma solidity 0.8.36;/pragma solidity 0.8.34;/' {} \;
#   sed -i '' 's/solc_version = "0.8.36"/solc_version = "0.8.34"/' <copy>/foundry.toml
# control (must reproduce the baseline exactly), then solx:
(cd <copy> && forge test --match-path test/unit/RbtcPurchaseTest.t.sol -j 1 --gas-report)
(cd <copy> && FOUNDRY_OUT=out-solx FOUNDRY_CACHE_PATH=cache-solx forge build --sizes --use /path/to/solx)
(cd <copy> && FOUNDRY_OUT=out-solx FOUNDRY_CACHE_PATH=cache-solx forge test --use /path/to/solx \
   --match-path test/unit/RbtcPurchaseTest.t.sol -j 1 --gas-report)

# solx -Oz needs a wrapper, because foundry cannot pass solx an -O level: pose as solc, inject
# settings.optimizer.mode = "z" into the standard-JSON on stdin, exec solx for everything else.

# Rootstock verifier capability (no deploy needed)
curl -s https://rootstock-testnet.blockscout.com/api/v2/smart-contracts/verification/config \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print([k for k in d if "compiler" in k]); \
    print([v for v in d["solidity_compiler_versions"] if v.startswith("v0.8.3")][:4])'
```
