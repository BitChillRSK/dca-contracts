# R24 — Test harness actually runs the lane it claims

Status: **assigned** · Assigned: yes · Optional/further-review: no

## Objective

Make local and fork test targets honest. `make moc-sovryn` must run Sovryn, `make fork-*` must be a legal Forge command, and Tropykus fork tests must pin a block from before kDOC mint was paused.

## Background

Three harness bugs, none of them protocol logic:

1. **`vm.setEnv("LENDING_PROTOCOL", tropykus)` in `BaseDeploymentTest.setUp`.** `vm.setEnv` writes the process environment. Every later suite in the same `forge test` process that reads `LENDING_PROTOCOL` (including `DcaDappTest`) then constructs as Tropykus. `make moc-sovryn` and `make dex-sovryn` report the same totals as Tropykus; Sovryn-only tests `vm.skip`. PR 49 found four pre-existing Sovryn failures this way (`RbtcPurchaseTest` deplete / run-out cases, all `ERC20: transfer amount exceeds balance`). They were invisible in CI.

2. **`make fork-*` passes `--no-match-path` twice.** PR 1 added `test/mainnet-debug/**` to `TEST_CMD`. `FORK_TEST_CMD` still appends `test/ai-generated/**`. Forge clap rejects a repeated flag, so fork targets never start. The original Makefile (Feb 2026) was valid because `TEST_CMD` had no path filter.

3. **Tropykus paused deposits on 2026-04-27.** Forking `latest` makes `make fork-tropykus` fail on mint. Pin a mainnet block from the day before. Sovryn mint is still live; `make fork-sovryn` stays on the tip.

The Sovryn deplete failures are the mock, not the handlers: `MockKdocToken` mints extra DOC when a redeem exceeds inventory (yield). `MockIsusdToken.burn` uses `ceilDiv` against a growing `tokenPrice` and does not, so a long purchase loop drains the mock’s DOC and reverts on `transfer`.

## Open product decisions

**none**

## Scope

- [ ] `Makefile`: `FORK_TEST_CMD` uses a **single** `--no-match-path` glob that excludes both `test/mainnet-debug/**` and `test/ai-generated/**`.
- [ ] `Makefile`: `make fork` and `make fork-tropykus` pass `--fork-block-number 8774377` (Rootstock mainnet, 2026-04-26, the day before Tropykus paused mint). `make fork-sovryn` does not pin.
- [ ] `Makefile`: every test target that sets `LENDING_PROTOCOL` also sets `EXPECTED_LENDING_PROTOCOL` to the same value so a canary can detect `vm.setEnv` overwrites.
- [ ] `BaseDeploymentTest.setUp`: stop writing `LENDING_PROTOCOL`. Keep `REAL_DEPLOYMENT=false`. Skip (do not `setEnv`) when `STABLECOIN_TYPE` is not DOC, because this suite always calls `DeployMocSwaps`. `NewHandlerDeploymentTest` must skip on the same lanes — `vm.skip` in the parent does not abort the child `setUp`.
- [ ] A canary test: `LENDING_PROTOCOL` still equals `EXPECTED_LENDING_PROTOCOL` after `BaseDeploymentTest.setUp` (and after `DcaDappTest` construction). On a Sovryn lane the deployed handler is Sovryn.
- [ ] `MockIsusdToken.burn`: if the mock holds less DOC than the (net) payout, mint the shortfall — same yield simulation as `MockKdocToken.redeemUnderlying`. The four Sovryn deplete / run-out tests must pass.
- [ ] `AGENTS.md`: remove the “`--no-match-path` twice” note; document the Tropykus fork-block pin; document that lanes must not `setEnv` `LENDING_PROTOCOL`.

## Out of scope

- [ ] Protocol / handler behaviour, fee model, R15 dust sweep, R22 folders.
- [ ] Changing CI’s required lanes (`make moc-sovryn` and USDRIF `dex-sovryn` stay).
- [ ] Running or requiring fork tests in CI (still need `RSK_MAINNET_RPC_URL`; still Anvil/revm, not rskj).
- [ ] `test/mainnet-debug/**`’s own older pin (`7911986`).
- [ ] Diagnosing Tropykus live mint pause beyond the fork-block pin.

## Files likely touched

- `Makefile`
- `test/unit/deployment/BaseDeploymentTest.t.sol`
- `test/mocks/MockIsusdToken.sol`
- `test/unit/RbtcPurchaseTest.t.sol` (only if a test assertion, not the mock, is wrong)
- new canary test under `test/unit/`
- `AGENTS.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md` (insert this PR between R1 and R15)
- `docs/relaunch/README.md`

## Required tests

```
# clap: fork target must not die on duplicate --no-match-path
# (will then fail on missing RPC if RSK_MAINNET_RPC_URL is unset — that is not a clap bug)
make fork-sovryn

# honest Sovryn lane, including NetRedemptionTest and the four deplete tests
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC EXPECTED_LENDING_PROTOCOL=sovryn \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --no-match-path "test/mainnet-debug/**" -j 1

# honest Tropykus lane still green
make moc-tropykus

make check
```

Fork tests with RPC: **not required** for the done-gate. If `RSK_MAINNET_RPC_URL` is set, `make fork-tropykus` should get past clap and fork block `8774377`.

Behaviours:

- After `BaseDeploymentTest.setUp`, `LENDING_PROTOCOL` equals `EXPECTED_LENDING_PROTOCOL`.
- `make moc-sovryn` constructs `DcaDappTest` with `s_lendingProtocolIndex == SOVRYN_INDEX` and does not skip `NetRedemptionTest` for protocol mismatch.
- The four `RbtcPurchaseTest` deplete / run-out tests pass on Sovryn mocks.
- `make fork-sovryn` no longer errors `the argument '--no-match-path <GLOB>' cannot be used multiple times`.

## Success criteria

- [ ] No `vm.setEnv("LENDING_PROTOCOL", …)` in first-party tests.
- [ ] Fork Make targets pass exactly one `--no-match-path`.
- [ ] Tropykus fork targets pin `8774377`; Sovryn fork targets do not.
- [ ] Canary fails if someone writes `LENDING_PROTOCOL` back to tropykus during a Sovryn lane.
- [ ] Four previously hidden Sovryn failures pass.
- [ ] `make check` passes, and the Sovryn lane’s skip/pass counts differ from Tropykus where Sovryn-only tests exist.
- [ ] Protocol invariants 1–7 unchanged.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold unless this spec explicitly changes one.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none (`Makefile` and test mocks only).
- Cutover: none.
