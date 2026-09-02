# R44 — OpenZeppelin 5.7 upgrade

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 31 of the relaunch stack. Stack on R39 (PR 30). Land before every remaining authority, storage, handler, and ABI PR.

## Objective

Upgrade the pinned OpenZeppelin Contracts dependency from `v4.9.3` to the latest stable `v5.7.0` before the fresh relaunch deploy, without mixing new BitChill behavior into the dependency migration.

## Background

The relaunch has no proxy or deployed storage to migrate. This is therefore the cheap point to take the supported major version, while the subsequent PRs can be written and tested against the dependency that will actually ship. OpenZeppelin 5 changes import paths, `Ownable` construction, revert formats, and some library APIs. Treat those as an explicit migration, not search-and-replace noise.

R39 lands first so the size comparison reflects the batch-only purchase surface. R45 then adds two-step ownership using the v5 implementation; do not add it here.

## Open product decisions

**none** — pin stable `v5.7.0`. Do not track `master`, a release candidate, or a floating 5.x reference.

## Scope

- [x] Update the `lib/openzeppelin-contracts` submodule pin and any remapping/import path required by v5.7.0.
- [x] Migrate first-party contracts and test mocks to v5 constructors and APIs while preserving the current owner at construction (`msg.sender`) in this PR.
- [x] Update tests that intentionally assert OZ revert data to v5 custom errors. Do not weaken them to generic `expectRevert()`.
- [x] Record before/after runtime sizes and gas snapshots for `DcaManager`, `OperationsAdmin`, and every concrete handler.
- [x] Inspect storage layouts. There is no proxy migration, but unexpected BitChill state reordering is still a review failure.
- [x] Exercise every OZ surface the repo uses: ownership, reentrancy guard, SafeERC20, ERC20/permit mocks, ERC165, and Math.

## Out of scope

- [ ] Ownable2Step or renounce policy (R45).
- [ ] Any BitChill selector, event, storage-field, fee, purchase, or routing behavior change.
- [ ] Upgrading Uniswap dependencies or changing solc/EVM pins.
- [ ] Live/testnet broadcasts.

## Files likely touched

- `lib/openzeppelin-contracts` submodule pin
- First-party OZ import/constructor call sites under `src/`
- OZ-based mocks under `test/mocks/`
- Tests that assert OZ4 revert strings
- `foundry.toml` or remappings only if v5 requires it

## Required tests

Run focused ownership/reentrancy/handler suites, `forge build --sizes`, `forge inspect` storage layouts, then `make check`, `make ci`, `make fork-sovryn`, and `make fork-tropykus`. The fork lanes are the Rootstock deployment/call smoke; do not broadcast.

## Success criteria

- [x] The repository is pinned exactly to OpenZeppelin Contracts `v5.7.0`.
- [x] Existing BitChill behavior is unchanged and v5 error assertions remain exact.
- [x] Every concrete contract remains below EIP-170 with recorded margin.
- [x] No unplanned BitChill storage-layout change.
- [x] No open product decisions.

## Measured results

Pinned to tag `v5.7.0` (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`), not a moving ref.

_Pre-optimizer figures (`optimizer = false`, no IR), the basis in force when this PR shipped — see [Measurement basis](./README.md#measurement-basis)._

**Runtime bytecode (EIP-170 limit 24,576) — every contract shrank; v5 replaced OZ's revert strings with custom errors:**

| contract | v4.9.3 | v5.7.0 | freed | margin after |
|---|---|---|---|---|
| `DcaManager` | 16,547 | 16,307 | 240 | 8,269 |
| `OperationsAdmin` | 4,528 | 4,277 | 251 | 20,299 |
| `IdleDocHandlerMoc` | 12,219 | 10,668 | 1,551 | 13,908 |
| `LayerBankDocHandlerMoc` | 17,111 | 15,364 | 1,747 | 9,212 |
| `SovrynDocHandlerMoc` | 16,638 | 14,930 | 1,708 | 9,646 |
| `TropykusDocHandlerMoc` | 16,894 | 15,147 | 1,747 | 9,429 |
| `SovrynErc20HandlerDex` | 22,173 | 20,660 | 1,513 | 3,916 |
| `TropykusErc20HandlerDex` | 22,429 | 20,916 | 1,513 | 3,660 |

The two Dex handlers are the binding constraint before R9. Their margin grows 2,403 → 3,916 and 2,147 → 3,660 (+63% and +71%).

**Gas (`forge snapshot`, MoC / Sovryn / DOC lane, same tests both sides):**

| operation | v4.9.3 | v5.7.0 | delta |
|---|---|---|---|
| deposit stablecoin | 182,056 | 175,350 | -6,706 |
| withdraw stablecoin | 123,716 | 122,836 | -880 |
| create schedule | 340,946 | 326,770 | -14,176 |
| length-1 batch purchase | 307,344 | 306,471 | -873 |
| 5-schedule batch purchase | 2,434,189 | 2,360,023 | -74,166 |
| withdraw accumulated rBTC | 4,653,258 | 4,573,041 | -80,217 |

Across the 578 shared tests no production path got more expensive. The only increases are ~+500 gas inside `*_reverts_notOwner` tests, which is the test building `abi.encodeWithSelector(OwnableUnauthorizedAccount, caller)` — test-side memory, not contract runtime.

**Storage layout.** Only `DcaManager` changed, and no BitChill variable moved relative to another. OZ 5.x `ReentrancyGuard` keeps `_status` at a fixed ERC-7201 namespaced slot instead of the next sequential slot, so `_status` leaves the sequential layout and every BitChill variable shifts down exactly one slot (`s_operationsAdmin` 2 → 1 … `s_scheduleNonce` 8 → 7). Every handler layout is byte-identical. The relaunch is a fresh deployment, so there is nothing to migrate. `DcaManager` now uses one fewer sequential slot, and the guard word sits at a collision-resistant namespaced slot rather than adjacent to BitChill state. This does not affect R18, which packs the `DcaDetails` struct inside `s_dcaSchedules` rather than DcaManager's own slots.

## Migration notes

The v5 API changes that actually touched this repo:

| v4.9.3 | v5.7.0 | where |
|---|---|---|
| `security/ReentrancyGuard.sol` | `utils/ReentrancyGuard.sol` | `DcaManager` |
| `Ownable()` | `Ownable(msg.sender)` | `DcaManager`, `OperationsAdmin`, `FeeHandler`, four mocks |
| `SafeERC20.safeApprove` | `SafeERC20.forceApprove` | `LendingErc20Handler.depositToken` |
| `Math.Rounding.Up` | `Math.Rounding.Ceil` | `TokenLending`, `LendingErc20Handler`, three handler tests |
| `"Ownable: caller is not the owner"` | `OwnableUnauthorizedAccount(address)` | 27 assertions |
| `"ReentrancyGuard: reentrant call"` | `ReentrancyGuardReentrantCall()` | 3 assertions |

`safeApprove` is the only one that changes behavior rather than spelling. v4 refused any non-zero → non-zero allowance change, so a stale partial allowance below the next deposit would have reverted every later deposit of that token; `forceApprove` zeroes first and succeeds. Pinned by `test_sovryn_depositSucceedsWithStaleNonZeroAllowance`, which was verified to fail when the v4 precondition is reinstated.

Ownership stays single-step and owned by the deployer. `Ownable2Step` is R45.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Dependency diff is the stable v5.7.0 tag, not a moving ref.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are direct migration fallout and named in the PR.

## ABI / deploy / cutover impact

- ABI: OZ-owned error data and ownership constructor plumbing may change; no first-party selector/event change.
- Scripts: compile-only constructor adaptation; ownership behavior stays single-step until R45.
- Cutover: fresh deployment only. No proxy/storage migration.
