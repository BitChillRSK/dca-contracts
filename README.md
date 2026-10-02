# BitChill DCA contracts

BitChill automates recurring purchases of rBTC with stablecoins on Rootstock (dollar-cost averaging).
A user deposits a listed stablecoin and creates a schedule on `DcaManager`. The deposit sits on a
handler, idle or supplied to a lending market, and an allowlisted swapper bot spends the schedule's
purchase amount on rBTC each time the schedule comes due. The rBTC accumulates on the handler until
the user withdraws it.

The contracts are immutable: there are no proxies and no owner migration of user funds.

`script/DeployFinal.s.sol` deploys one `OperationsAdmin`, one `DcaManager`, and seven handlers:

| Stablecoin | Route 0 (idle) | Route 1 (LayerBank) | Route 2 (Sovryn) | Purchase venue |
|---|---|---|---|---|
| DOC | `IdleDocHandlerMoc` | `LayerBankDocHandlerMoc` | `SovrynDocHandlerMoc` | Money on Chain |
| USDRIF | `IdleHandlerDex` | `LayerBankHandlerDex` | — | Uniswap V3 |
| USDT0 | `IdleHandlerDex` | `LayerBankHandlerDex` | — | Uniswap V3 |

Security reviewers should start with [`AUDIT_GUIDE.md`](./AUDIT_GUIDE.md): scope, trust boundaries,
accounting and scheduling properties, accepted risks, and the release gates. To report a
vulnerability, see [`SECURITY.md`](./SECURITY.md).

## Contracts

```
DcaManager          user and swapper entry point; the schedule ledger; holds no funds
OperationsAdmin     route classes, (token, route) → handler registry, swapper allowlist, deposit pause

Custody
  TokenHandler      deposit and withdraw one stablecoin
  IdleHandler       TokenHandler that keeps the stablecoin on the handler
  LendingHandler    TokenHandler with per-user virtual shares, interest, and exact share redemption
    LayerBankHandler, SovrynHandler      protocol adapters

Purchase
  PurchaseFees      fee curve and fee collector; carries handler ownership
  PurchaseRbtc      shared batch pipeline, accumulated-rBTC books, withdrawal to the user
    PurchaseMoc     redeems DOC for rBTC at Money on Chain
    PurchaseUniswap swaps to WRBTC on Uniswap V3 under an oracle floor; unwraps on withdrawal

Deployed handler = one custody base + one purchase base, constructor only:
  src/idle/         IdleDocHandlerMoc, IdleHandlerDex
  src/layerbank/    LayerBankDocHandlerMoc, LayerBankHandlerDex
  src/sovryn/       SovrynDocHandlerMoc, SovrynHandlerDex (not in the production map)
  src/tropykus-legacy/   test-only; never deployed
```

Function-level documentation is NatSpec on the interfaces in `src/interfaces/`. Each deployed contract
also states its own security and lifecycle model in its header.

## Purchase fees

Each handler has owner-configurable minimum and maximum rates and a lower purchase threshold. At or
below the threshold the maximum rate applies; above it the effective rate decreases smoothly toward
the minimum while the absolute fee never decreases as the purchase grows. Equal rates give a flat fee.
The fee is taken as a share of the rBTC bought, not withheld from the stablecoin spent. Launch
settings are 1% up to 250 tokens, decreasing toward 0.2% above that.

[`docs/PURCHASE_FEES.md`](./docs/PURCHASE_FEES.md) has the curve, the exact integer rounding, and the
batch allocation.

## Development

Requires [Foundry](https://book.getfoundry.sh/). CI pins forge v1.7.1; a different version can format
differently and fail `make fmt-check`.

```bash
git clone git@github.com:BitChillRSK/dca-contracts.git
cd dca-contracts
git submodule update --init --recursive
forge build
```

### Testing

The shared test harness deploys one stack per run, selected by three environment variables, so tests
run in lanes. Use the `make` targets: a bare `forge test` fails without `SWAP_TYPE` and
`LENDING_PROTOCOL`.

| Variable | Values |
|---|---|
| `SWAP_TYPE` | `mocSwaps` (DOC through Money on Chain), `dexSwaps` (Uniswap V3) |
| `LENDING_PROTOCOL` | `none` (idle), `layerbank`, `sovryn`, `tropykus` (legacy mocks) |
| `STABLECOIN_TYPE` | `DOC`, `USDRIF`, `USDT0` |

```bash
make check          # build, license and format checks, every production lane, stateful invariants
make check-deploy   # the same lanes against the via-IR bytecode that ships; slow

# single lanes
make moc-none                               # DOC, idle
make moc-layerbank                          # DOC, LayerBank
make moc-sovryn                             # DOC, Sovryn
STABLECOIN_TYPE=USDRIF make dex-none        # USDRIF, idle (also USDT0)
STABLECOIN_TYPE=USDT0 make dex-layerbank    # USDT0, LayerBank (also USDRIF)
make invariants-sovryn                      # stateful fuzzing: 64 runs × 512 calls

# one test file in a chosen lane
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/DcaDappTest.t.sol -vvv
```

Fork tests run against live Rootstock state and need `RSK_MAINNET_RPC_URL` in `.env` (copy
`.env.example`). They are not in CI.

```bash
make fork-sovryn
make fork-layerbank
make fork-dex-path    # Dex path allowlist against live Uniswap pools
```

`make help` lists every target, including the Tropykus mock lanes and the live probes under
`test/mainnet-debug/`. [`test/ai-generated/fuzz/README_INVARIANTS.md`](./test/ai-generated/fuzz/README_INVARIANTS.md)
describes what each invariant suite proves.

### Static analysis

```bash
make slither
make aderyn
```

Both analyze `src/` only. Slither exits non-zero while triaged findings remain; the triage is in
[`docs/relaunch/R73-RELEASE_RECORD.md`](./docs/relaunch/R73-RELEASE_RECORD.md#static-analysis-triage).

## Deployment

The shipped bytecode is built under `[profile.deploy]` (`via_ir = true`). Every broadcast needs
`FOUNDRY_PROFILE=deploy` in its environment: without it `forge script` compiles and deploys the
default no-IR artifact, which is not the bytecode `make check-deploy` validated. Run
`make check-deploy` green on the exact commit before broadcasting.

```bash
REAL_DEPLOYMENT=true \
INITIAL_SWAPPER=<bot-eoa> \
FOUNDRY_PROFILE=deploy \
forge script script/DeployFinal.s.sol:DeployFinal \
  --rpc-url $RSK_MAINNET_RPC_URL \
  --account <deployer-keystore> \
  --broadcast --legacy \
  --verify --verifier blockscout --verifier-url $BLOCKSCOUT_API_URL
```

`DeployFinal.run()` is mainnet-only and reverts on any missing address or incomplete route map. Sign
with a Foundry keystore (`--account`) or a hardware wallet (`--ledger`), not a raw private key.

`DeployMocSwaps`, `DeployDexSwaps`, and the add-on scripts (`DeployIdleHandler`,
`DeployLayerBankHandler`, `DeployUsdrifHandler`) serve the test lanes and later handler additions.
`DeployMocAndUniswap` is a local comparison harness and reverts on `REAL_DEPLOYMENT=true`.

### Ownership after deploy

A Safe cannot sign a Foundry broadcast, so an EOA deploys. The script constructs all nine contracts
with that EOA as owner, configures them, and calls `transferOwnership(MAINNET_OWNER)` on each, which
only proposes the Safe. The Safe then sends `acceptOwnership()` to each contract. Until it does, the
deploying EOA is still the owner. `renounceOwnership` always reverts.

[`docs/relaunch/CUTOVER_RUNBOOK.md`](./docs/relaunch/CUTOVER_RUNBOOK.md) is the full operator
sequence: preconditions, post-deploy checks, adding a handler to a live deployment, and what to do
about a compromised swapper key or a fee collector rotation.

## Documentation

| Document | Contents |
|---|---|
| [`AUDIT_GUIDE.md`](./AUDIT_GUIDE.md) | Scope, trust model, properties, accepted risks, release gates |
| [`SECURITY.md`](./SECURITY.md) | Vulnerability reporting and incident response |
| [`audits/`](./audits/README.md) | Review reports |
| [`ADDRESSES.md`](./ADDRESSES.md) | External contracts the deployment binds to |
| [`docs/PURCHASE_FEES.md`](./docs/PURCHASE_FEES.md) | Fee math |
| [`docs/relaunch/`](./docs/relaunch/README.md) | One design record per change, and the cutover runbook |
| [`AGENTS.md`](./AGENTS.md) | Contributor rules and the protocol invariants |

## License

`src/` is licensed under [BUSL-1.1](./LICENSE): non-production use is granted, and the license changes
to `GPL-2.0-or-later` on 2030-09-07. `script/` and `test/` are MIT.

## Contact

Smart contract developer: [Antonio Rodríguez-Ynyesto](https://www.linkedin.com/in/antonio-maria-rodriguez-ynyesto-sanchez/).
Security reports go through [`SECURITY.md`](./SECURITY.md).

## Disclaimer

No audit or test suite guarantees safety. Do your own diligence and risk only funds you can afford to
lose.
