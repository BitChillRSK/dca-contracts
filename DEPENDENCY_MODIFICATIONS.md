# Dependency Modifications

## Solidity / EVM pins (R23)

First-party contracts compile with:

- `solc_version = "0.8.36"` (latest stable `0.8.x` as of 2026-08-15)
- `evm_version = "cancun"`

Rootstock executes `PUSH0` since Arrowhead (2024-04-03) and Cancun memory / transient opcodes (`MCOPY`, `TLOAD`/`TSTORE`) since Lovell (2025-03). `cancun` is the newest Foundry target whose *used* opcodes the chain runs. Do not set `prague` / `osaka` / `amsterdam`. Do not use `blobhash` / `block.blobbasefee` in first-party code. Deployed bytecode must not start with `0xEF` (Rootstock Vetiver rejects EOF).

`[profile.deploy]` sets the same `solc_version` and `evm_version` (plus `via_ir` for size).

Anvil and `forge test --fork-url` execute on revm, not rskj. Prove the pin on Rootstock **testnet** before merging relaunch behavior PRs (see `docs/relaunch/IMPLEMENTATION_ORDER.md`).

OpenZeppelin stays **v4.9.3**. Do not re-run any `sed` on `lib/openzeppelin-contracts`. A 5.x upgrade is a separate optional PR. Compiling OZ 4.9.3 with 0.8.36 emits warning 6335 (`error` will become a keyword in `ECDSA._throwError`); that is expected and not a reason to bump OZ in this PR.

Rootstock does **not** require Solidity 0.8.19. That pin was a blunt way to stay off `PUSH0` before Arrowhead; `evm_version = "london"` on a newer solc would have been enough at the time.

## Uniswap V3 pragma patch

Uniswap V3 Core, V3 Periphery, and Swap Router Contracts still declare `pragma solidity =0.7.6` in git. First-party Dex sources (`PurchaseUniswap` and the Dex handlers) import those files.

Tried and **rejected** in R23:

1. Unpatched Uniswap + a single project compiler `0.8.36` — Foundry reports no solc that satisfies `=0.7.6`.
2. Unpatched Uniswap + Foundry `compilation_restrictions` pinning `lib/v3-core/**`, `lib/v3-periphery/**`, and `lib/swap-router-contracts/**` to `=0.7.6` / `istanbul` — still fails. Restrictions apply to importers as well, so a `pragma solidity 0.8.36` file that imports Uniswap cannot share a compilation unit with `=0.7.6`.

Therefore Uniswap is **not** compiled with solc 0.7.6 in this repo. Git submodules stay at upstream `=0.7.6`. Local builds and CI patch only the pragma so the same 0.8.36 / cancun compiler can parse those sources:

```bash
make patch-deps
```

`setup.sh`, `make build` / `make check`, and CI all use this target. The patch mutates vendored submodules under `lib/`; those submodule dirties are expected locally after setup and must not be staged in BitChill PRs.

### Affected files

Pragma `=0.7.6` → `>=0.7.6 <0.9.0` in:

- `lib/v3-core/`
- `lib/v3-periphery/`
- `lib/swap-router-contracts/`

### Justification

1. Foundry cannot mix a pinned first-party `0.8.36` compilation unit with imported `=0.7.6` Uniswap sources.
2. The patch is pragma-only. It does not change Uniswap bytecode we deploy (we call live Rootstock Uniswap; Dex handlers are not in this relaunch's deploy default).
3. This is more maintainable than forking those dependencies. The patch is re-applied after `forge update` / a clean submodule checkout.

### Verification

`forge build`, `make moc-sovryn`, and `STABLECOIN_TYPE=USDRIF make dex-sovryn` must pass after `make patch-deps`. Uniswap submodule diffs must remain unstaged.
