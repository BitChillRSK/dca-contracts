# Dependency Modifications

## Solidity / EVM pins (R23)

First-party contracts compile with:

- `solc_version = "0.8.36"` (latest stable `0.8.x` as of 2026-08-15)
- `evm_version = "cancun"`

Rootstock executes `PUSH0` since Arrowhead (2024-04-03) and Cancun memory / transient opcodes (`MCOPY`, `TLOAD`/`TSTORE`) since Lovell (2025-03). `cancun` is the newest Foundry target whose *used* opcodes the chain runs. Do not set `prague` / `osaka` / `amsterdam`. Do not use `blobhash` / `block.blobbasefee` in first-party code. Deployed bytecode must not start with `0xEF` (Rootstock Vetiver rejects EOF).

`[profile.default]` sets `solc_version` and `evm_version` and compiles with `via_ir = false`.
`[profile.deploy]` ([R60](./docs/relaunch/R60-src-only-via-ir.md)) inherits both pins and sets
`via_ir = true`: it is the bytecode that ships, and `make check-deploy` runs the suite against it. The
Solx / via-IR evaluation behind that choice is R55 in [#105](https://github.com/BitChillRSK/dca-contracts/pull/105).

Anvil and `forge test --fork-url` execute on revm, not rskj. Prove the pin on Rootstock **testnet** before merging relaunch behavior PRs (see `docs/relaunch/IMPLEMENTATION_ORDER.md`).

OpenZeppelin is pinned to **v5.7.0** (tag `cab19933c33c2ad1d4c7a84864a3601dddfd16f3`), migrated from `v4.9.3` in R44 — see [`docs/relaunch/R44-openzeppelin-5-upgrade.md`](./docs/relaunch/R44-openzeppelin-5-upgrade.md) for the API deltas, sizes, gas, and the `DcaManager` storage-slot shift. Track the stable tag; do not follow `master`, a release candidate, or a floating `5.x` ref.

Do not run any `sed` on `lib/openzeppelin-contracts`; OZ ships pragmas that solc 0.8.36 already accepts.

The old warning 6335 note (`error` becoming a keyword in `ECDSA._throwError`) applied to 4.9.3 and no longer fires: 0.8.36 compiles v5.7.0 without it.

`lib/openzeppelin-contracts` carries its own nested submodules (`forge-std`, `erc4626-tests`, `halmos-cheatcodes`) for OpenZeppelin's own test suite. First-party builds never compile them, but CI checks out `submodules: recursive`, and switching the OZ pin can leave their gitlinks drifted — which shows up as `modified: lib/openzeppelin-contracts (modified content)` with no `.sol` diff behind it. That is not the pragma patch. Resync with `git submodule update --init --recursive --force lib/openzeppelin-contracts`; never stage it.

Rootstock does **not** require Solidity 0.8.19. That pin was a blunt way to stay off `PUSH0` before Arrowhead; `evm_version = "london"` on a newer solc would have been enough at the time.
