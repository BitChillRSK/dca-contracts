# R23 — Toolchain and dependency baseline

Status: **implemented — awaiting user confirmation** · Assigned: yes · Optional/further-review: no

## Objective

Pin first-party Solidity to the latest stable `0.8.x` and Foundry `evm_version` to `cancun` so later relaunch PRs compile against the newest Rootstock-executable EVM. Rewrite `DEPENDENCY_MODIFICATIONS.md` so it matches those pins and records whether the Uniswap pragma patch is still required.

## Background

Production pinned `solc 0.8.19` + `evm_version = "london"` because older Rootstock lacked `PUSH0`. Rootstock has executed `PUSH0` since Arrowhead (2024-04-03) and Cancun memory/transient opcodes (`MCOPY`, `TLOAD`/`TSTORE`) since Lovell (2025-03). Consensus cares about opcodes in bytecode, not the solc number.

As of 2026-08-15 the latest stable Solidity is **0.8.36** (2026-07-09). Rootstock docs listing solc 0.8.34 are a portal/verification hint, not a consensus cap. Prefer 0.8.36 unless Blockscout verification or a known solc bug forces the docs pin.

`cancun` is the newest Foundry target whose *used* opcodes Rootstock executes. Do not set `prague` / `osaka` / `amsterdam`. Do not use blob opcodes. OpenZeppelin stays `v4.9.3` (a 5.x upgrade is a later optional PR).

Uniswap V3 sources still declare `pragma solidity =0.7.6`. Today `make patch-deps` rewrites those to `>=0.7.6 <0.9.0` and the whole project compiles with the first-party compiler. Foundry `compilation_restrictions` that pin Uniswap to 0.7.6 are likely to conflict because `PurchaseUniswap` imports those files (restrictions apply to importers). This PR must **prove** which mix actually builds, then document that — do not assume both the patch and 0.7.6 overrides exist (current `foundry.toml` has no overrides).

## Scope

- [x] Set `solc_version = "0.8.36"` and `evm_version = "cancun"` in `[profile.default]`. Set the same two keys explicitly on `[profile.deploy]` (do not omit them there even if inherit would work).
- [x] Change first-party `pragma solidity` in `src/`, `test/`, and `script/` to match `0.8.36` (`^0.8.19` scripts become exact `0.8.36`). Do not change `lib/`.
- [x] Keep OpenZeppelin at `v4.9.3`. Do not bump Uniswap submodules.
- [x] Experiment, in this order, and keep the first mix that builds first-party + Dex sources:
  1. Unpatched Uniswap (`=0.7.6`) + Foundry `compilation_restrictions` / additional compiler profiles pinning those libs to `0.7.6` (and an EVM 0.7.6 supports, e.g. `istanbul`).
  2. If that fails because first-party files import Uniswap: keep compiling Uniswap with 0.8.36 via `make patch-deps` (current approach). Do not compile Uniswap with prague/osaka/amsterdam.
- [x] Rewrite `DEPENDENCY_MODIFICATIONS.md` to record the pins, why `cancun` (not prague), OZ 4.9.3 unchanged, Uniswap 0.7.6 sources unchanged in git, and whether the pragma `sed` is still required.
- [x] Update agent/user docs that still claim Rootstock requires 0.8.19 / london: `AGENTS.md`, `README.md`.
- [x] Confirm `make patch-deps` / CI / `setup.sh` match the Uniswap-patch decision. If the patch is still required, leave those call sites; if overrides alone work, stop patching submodule files.
- [x] After `forge build`, confirm first-party artifacts report compiler `0.8.36` and `evmVersion: cancun`. Runtime bytecode must not start with `0xEF`. Do not introduce `blobhash` / `block.blobbasefee`.

## Out of scope

- [ ] OpenZeppelin 5.x migration.
- [ ] Any handler, fee, schedule, event, or accounting behavior change (R1–R22).
- [ ] Moving sources into `src/sovryn/` / `src/layerbank/` / `src/idle/` / `src/tropykus-legacy/` (R22).
- [ ] Deploy broadcasts, live addresses, or testnet txs from this PR. A local Rootstock-fork *compile/deploy smoke* is allowed if `RSK_MAINNET_RPC_URL` is present; if it is not, document the skip and do not block the PR on it.
- [ ] `forge fmt` of existing files.
- [ ] Changing `test/ai-generated/fuzz/README_INVARIANTS.md` unless a test file there fails to compile (pragma bump only in that case).
- [ ] `dca-out-contracts`.

## Files likely touched

- `foundry.toml`
- `DEPENDENCY_MODIFICATIONS.md`
- `AGENTS.md`
- `README.md`
- `Makefile` (only if the Uniswap-patch decision changes `patch-deps`)
- `.github/workflows/test.yml` (only if CI must stop or keep `make patch-deps`)
- `setup.sh` (only if the patch decision changes)
- First-party `pragma solidity` in `src/`, `src/interfaces/`, `test/`, `script/`
- `docs/relaunch/README.md` (assignment status)

Implementer may follow compiler errors into mocks and tests. Extra files belong in the PR write-up.

## Required tests

Commands:

```bash
forge build
# Artifact pin check (DcaManager metadata): compiler 0.8.36, evmVersion cancun, deployed bytecode not 0xEF-prefixed
make moc-sovryn
STABLECOIN_TYPE=USDRIF make dex-sovryn
```

Local done-gate after those lanes: `make check` (also runs `make moc-tropykus`).

Behaviors to assert:

- First-party sources compile at 0.8.36 / cancun.
- Dex/Uniswap import path still compiles (even though USDRIF/Uniswap is not this relaunch's deploy default).
- Uniswap git submodules are not committed dirty; if `patch-deps` still mutates `lib/`, that dirt stays unstaged.
- No first-party use of `blobhash` / `block.blobbasefee`.
- OpenZeppelin remains 4.9.3 (`lib/openzeppelin-contracts` not upgraded).

Fork tests: not required for merge, and **not** a Rootstock opcode proof (Anvil/revm). After this PR’s bytecode exists, a human/ops Rootstock **testnet** deploy of one first-party contract is the proof that later relaunch PRs may merge on this pin (`IMPLEMENTATION_ORDER.md`). Fallback if that node rejects cancun: `shanghai` (PUSH0 only) or portal-listed solc 0.8.34, still not london unless the node rejects shanghai — land the fallback on this branch before merging PR 3+.

## Success criteria

- [x] First-party pragma / `solc_version` are `0.8.36`; `evm_version` is `cancun` (or a documented fallback after a failed Rootstock fork smoke).
- [x] `[profile.deploy]` sets the same compiler and EVM pins.
- [x] Uniswap sources stay 0.7.6 in git; OZ still 4.9.3.
- [x] The Uniswap compile mix is proven and written down (patch still required vs overrides alone).
- [x] `DEPENDENCY_MODIFICATIONS.md` no longer says Rootstock requires 0.8.19.
- [x] `forge build`, `make moc-sovryn`, and `STABLECOIN_TYPE=USDRIF make dex-sovryn` pass.
- [x] First-party artifact metadata matches the pins; deployed bytecode does not start with `0xEF`.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct compiler-error fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.
- [ ] No `lib/` submodule dirties committed.

## ABI / deploy / cutover impact

- ABI: none (pragma/compiler only; no function or event changes).
- Scripts: none unless a compile-only smoke is added; no broadcast.
- Cutover: new deployment bytecode will include `PUSH0` and may include Cancun memory opcodes. Do not deploy this compiler pin to a chain that lacks them. Frontend/ops: none until a later deploy PR.
