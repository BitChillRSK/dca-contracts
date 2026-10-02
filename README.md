# BitChill DCA contracts

BitChill automates recurring purchases of rBTC with stablecoins on Rootstock (dollar-cost averaging).
A user deposits a listed stablecoin and creates a schedule on `DcaManager`. The deposit sits on a
handler, idle or supplied to a lending market, and an allowlisted swapper bot spends the schedule's
purchase amount on rBTC each time the schedule comes due. The rBTC accumulates on the handler until
the user withdraws it.

The contracts are immutable: there are no proxies and no owner migration of user funds.

Three stablecoins are listed. DOC can sit idle, in LayerBank, or in Sovryn, and is redeemed for rBTC
at Money on Chain. USDRIF and USDT0 can sit idle or in LayerBank, and are swapped for rBTC on Uniswap
V3. The route table, with the contract deployed on each route, is under
[Production scope](./AUDIT_GUIDE.md#production-scope) in the audit guide.

Security reviewers should start with [`AUDIT_GUIDE.md`](./AUDIT_GUIDE.md): scope, trust boundaries,
accounting and scheduling properties, accepted risks, and the release gates. To report a
vulnerability, see [`SECURITY.md`](./SECURITY.md).

## Contracts

Within the custody and purchase branches, indentation is inheritance: each contract inherits the one
it is nested under.

```
DcaManager            user and swapper entry point; the schedule ledger; holds no funds
OperationsAdmin       route classes, (token, route) → handler registry, swapper allowlist, deposit pause

Shared bases
  BitChillOwnable           two-step ownership, no renounce
                            inherited by DcaManager, OperationsAdmin, PurchaseFees
  DcaManagerAccessControl   immutable DcaManager address and the onlyDcaManager modifier
                            inherited by TokenHandler, PurchaseRbtc
  StablecoinSource          immutable stablecoin and the batch-funding hook
                            inherited by TokenHandler, PurchaseRbtc

Custody branch
  TokenHandler              deposit and withdraw one stablecoin
    IdleHandler             keeps the stablecoin on the handler
    LendingHandler          per-user virtual shares, interest, exact share redemption
      LayerBankHandler      protocol adapter
      SovrynHandler         protocol adapter

Purchase branch
  PurchaseFees              fee curve and fee collector; makes every handler ownable
    PurchaseRbtc            shared batch pipeline, accumulated-rBTC books, withdrawal to the user
      PurchaseMoc           redeems DOC for rBTC at Money on Chain
      PurchaseUniswap       swaps to WRBTC on Uniswap V3 under an oracle floor; unwraps on withdrawal

Deployed handlers: constructor only, each inheriting one custody contract and one purchase contract
  src/idle/         IdleDocHandlerMoc   = IdleHandler + PurchaseMoc
                    IdleHandlerDex      = IdleHandler + PurchaseUniswap
  src/layerbank/    LayerBankDocHandlerMoc = LayerBankHandler + PurchaseMoc
                    LayerBankHandlerDex    = LayerBankHandler + PurchaseUniswap
  src/sovryn/       SovrynDocHandlerMoc = SovrynHandler + PurchaseMoc
                    SovrynHandlerDex    = SovrynHandler + PurchaseUniswap   (not in the production map)
  src/tropykus-legacy/   test-only; never deployed
```

Function-level documentation is NatSpec on the interfaces in `src/interfaces/`. Each deployed contract
also states its own security and lifecycle model in its header.

## Purchase fees

Each handler has owner-configurable minimum and maximum rates and a lower purchase threshold. At or
below the threshold the maximum rate applies; above it the effective rate decreases smoothly toward
the minimum while the absolute fee never decreases as the purchase grows. Equal rates give a flat fee.
The fee is taken as a share of the rBTC bought, not withheld from the stablecoin spent. The launch
settings are under [Launch configuration](./AUDIT_GUIDE.md#launch-configuration).

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
run in lanes. Use the `make` targets, which set all three. The harness has no fallback for `SWAP_TYPE`
or `LENDING_PROTOCOL`: a bare `forge test` fails without them, and forge also reads them from `.env`
if they are set there.

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
  forge test --match-path test/unit/DcaScheduleTest.t.sol -vvv
```

Fork tests run against live Rootstock state and need `RSK_MAINNET_RPC_URL` in `.env`. They are not in
CI.

```bash
make fork-sovryn
make fork-layerbank
make fork-dex-path    # Dex path allowlist against live Uniswap pools
```

`make help` lists the remaining lanes, including the Tropykus mock lanes and the live probes under
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

`script/DeployFinal.s.sol` is the production script. `run()` is mainnet-only and reverts on any
missing address or incomplete route map. The broadcast command and the steps around it are in
[`docs/relaunch/CUTOVER_RUNBOOK.md`](./docs/relaunch/CUTOVER_RUNBOOK.md#deploy). Sign with a Foundry
keystore (`--account`) or a hardware wallet (`--ledger`), not a raw private key.

`DeployMocSwaps`, `DeployDexSwaps`, and the add-on scripts (`DeployIdleHandler`,
`DeployLayerBankHandler`, `DeployUsdrifHandler`) build the stacks the test lanes use. They are not the
production path, although the two lane scripts also have testnet and mainnet branches.
`DeployMocAndUniswap` is a local comparison harness and reverts on `REAL_DEPLOYMENT=true`.

### Ownership after deploy

The operator procedures are in [`docs/relaunch/CUTOVER_RUNBOOK.md`](./docs/relaunch/CUTOVER_RUNBOOK.md):

- [Ownership handoff](./docs/relaunch/CUTOVER_RUNBOOK.md#ownership-handoff), mainnet and testnet
- [Adding a handler after cutover](./docs/relaunch/CUTOVER_RUNBOOK.md#adding-a-handler-after-cutover):
  the order in which the Safe registers the route, sets the token minimum, and assigns the handler
- [Compromised swapper](./docs/relaunch/CUTOVER_RUNBOOK.md#compromised-swapper)
- [Fee collector rotation](./docs/relaunch/CUTOVER_RUNBOOK.md#fee-collector-rotation)

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
