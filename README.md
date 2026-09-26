# BitChill - Smart Contracts

## Introduction

BitChill is a smart-contract protocol on Rootstock that enables users to automate BTC purchases with
Dollar-Cost Averaging (DCA). Users deposit listed stablecoins into handlers (idle custody or lending),
create schedules on `DcaManager`, and a swapper bot triggers purchases. `DeployFinal` creates this
production map:

| Stablecoin | Routes | Venue |
|---|---|---|
| DOC | idle (0), LayerBank (1), Sovryn (2) | Money on Chain |
| USDRIF | idle (0), LayerBank (1) | Uniswap V3 |
| USDT0 | idle (0), LayerBank (1) | Uniswap V3 |

Tropykus remains in-repo for local and pinned-fork adapter coverage only; no live script deploys it.

Security reviewers should start with [`AUDIT_GUIDE.md`](./AUDIT_GUIDE.md). It defines the production
scope, trust boundaries, accounting and scheduling properties, known limitations, and reproducible
release gates without requiring the historical implementation notes.

## Protocol Architecture

### Core Components

1. **DcaManager**
   - Central contract managing all DCA operations
   - It is the only contract users shall interact with through BitChill's UI to create, delete or modify their DCA schedules
   - It is the only contract the CRON job will interact with to trigger the purchases
   - Keeps track of users' DCA schedules
   - Implements access control and security checks

2. **Token Handlers**
   - Base contract: `TokenHandler` abstract contract
   - Implements core token operations and access control
   - Holds idle stablecoin or lending receipt shares on behalf of users
   - Handles deposits and withdrawals of stablecoins

3. **Lending Integration**
   - `TokenLending` / `LendingErc20Handler`: share ↔ underlying conversion and per-user virtual shares
   - Production lending adapters: LayerBank (index 1), Sovryn (index 2 for DOC)
   - Idle handlers (index 0) hold the stablecoin without lending

4. **Purchase Methods**
   - `PurchaseMoc`: Direct redemption through Money on Chain (for DOC)
   - `PurchaseUniswap`: Swaps through Uniswap V3 (for other stablecoins)

### Architecture Design Considerations

The protocol was designed with extensibility in mind, supporting multiple purchase methods and stablecoins:

1. Money on Chain (MoC) for DOC:
   - Primary-market redemption rather than an AMM route
   - Direct redemption mechanism
   - No AMM pool slippage; Money on Chain availability and pricing remain external dependencies

2. Uniswap V3 for other stablecoins:
   - Supports approved dollar-pegged ERC20 stablecoins with at most 18 decimals
   - Market-based pricing
   - Owner-configurable slippage protection
   - Path optimization for best rates

### Gas Efficiency Considerations

The current architecture balances extensibility with gas efficiency:

1. Multiple inheritance layers to support different purchase methods
2. Optimized purchase paths for each stablecoin type
3. Batch processing for gas savings

## Features

1. **DCA Schedules**
   - Create, update, and delete DCA schedules
   - Multiple schedules per user and token
   - Configurable purchase amounts and periods
   - Yield accrual on lending routes; idle routes do not generate yield

2. **Token Management**
   - Support for DOC, USDRIF, and USDT0 on the production map
   - Integration with LayerBank and Sovryn (DOC); idle custody where chosen
   - Interest accrual and withdrawal on lending routes
   - Fee management system

3. **Security properties**
   - Safe governance, a separate swapper allowlist, and handler entry points restricted to `DcaManager`
   - Reentrancy guards on user schedule mutations and checks-effects-interactions on purchases
   - Balance-delta accounting around external token, lending, MoC, and Uniswap interactions

4. **Batch Processing**
   - Gas-efficient batch purchases
   - Optimized for multiple users

## Security Considerations

### Access Control
- Owner governance via `Ownable2Step` (Safe after cutover accept)
- Swapper allowlist on `OperationsAdmin` for purchase operations
- `DcaManager` as the only user-facing entry for schedules and withdrawals

### Reentrancy Protection
- ReentrancyGuard implementation
- Checks-Effects-Interactions pattern
- Safe token transfers using SafeERC20

### Input Validation
- Comprehensive parameter validation
- Range checks for amounts and periods
- Schedule existence verification
- Balance checks before operations

### Contract Dependencies
- Rootstock-compatible compiler: solc **0.8.36**, EVM **cancun**
- OpenZeppelin Contracts **v5.7.0**
- Money on Chain (DOC redemptions)
- Uniswap V3 SwapRouter02 (Dex stables)
- Deployment profile: `FOUNDRY_PROFILE=deploy` (`via_ir = true`) — see below

### Key Security Assumptions
1. Money on Chain protocol security (for DOC)
2. Uniswap V3 protocol security (for other stablecoins)
3. Token contract integrity
4. Lending protocol reliability

### Known Limitations
1. Governance controls configuration and the swapper controls purchase liveness and batch selection.
2. External tokens, lending venues, Money on Chain, Uniswap, WRBTC, and the price oracle can fail or
   become unavailable.
3. Deployments are immutable. Handler recovery uses a new route and manual user exit/re-entry.
4. Fee-on-transfer tokens and asynchronous or partial lending redemptions are unsupported.
5. Batches are atomic, and missed cadence slots are skipped rather than caught up.

See [`AUDIT_GUIDE.md`](./AUDIT_GUIDE.md) for the exact boundaries behind these summaries.

### Audit and Testing

Two published reviews by Ivan Fitro (April and June 2025) cover the **pre-relaunch** codebase. Details and
the boundary with the 2026 relaunch are in [`audits/README.md`](./audits/README.md). The relaunch stack has
not claimed a separate independent audit in that file unless a new report is added.

Local automation includes unit tests, fuzz/invariants, and fork probes. Static analysis at cutover:
`make slither`, `make aderyn` (triage in [`docs/relaunch/R73-RELEASE_RECORD.md`](./docs/relaunch/R73-RELEASE_RECORD.md)).

**No audit or test suite guarantees absolute safety.** Do your own diligence and only risk funds you can afford to lose.

## Getting Started

### Prerequisites
- Rust
- Foundry
- Rootstock RPC access

### Installation
```bash
git clone git@github.com:BitChillRSK/dca-contracts.git
cd dca-contracts
git submodule update --init --recursive
forge build
```

### Testing
```bash
# Local done-gate: every production MoC/Dex funding lane plus Sovryn invariants
make check

# Run tests with DOC and idle funds (index 0)
make moc-none

# Run tests with DOC and LayerBank (index 1)
make moc-layerbank

# Run tests with DOC and Sovryn (index 2)
make moc-sovryn

# Legacy Tropykus mocks. Tropykus is on neither live map (index 4 is burned); these lanes
# exercise LendingErc20Handler through a second adapter.
make moc-tropykus

# Run tests with USDRIF and Tropykus (legacy lane)
STABLECOIN_TYPE=USDRIF make dex-tropykus

# Run tests with USDRIF and Sovryn
STABLECOIN_TYPE=USDRIF make dex-sovryn

# Run specific test file with custom parameters
STABLECOIN_TYPE=USDRIF SWAP_TYPE=dexSwaps LENDING_PROTOCOL=tropykus forge test --match-path test/unit/DcaDappTest.t.sol -vvv

# -------------------------------
# Invariant & Fuzz Testing
# -------------------------------
# Foundry-based fuzzing and invariants live in `test/ai-generated/fuzz`. A detailed guide
# is available at test/ai-generated/fuzz/README_INVARIANTS.md.
#
# Quick examples:
#
# Run the full invariant suite with Tropykus (default)
forge test --match-contract InvariantTest
#
# Same suite but forcing Sovryn mocks
LENDING_PROTOCOL=sovryn forge test --match-contract InvariantTest
#
# Run a single invariant (e.g. deposit-vs-lending consistency)
forge test --match-test invariant_totalDepositedTokensMatchesLendingProtocol -vv
```

### Deployment

#### 🔐 Secure Wallet Management (Recommended)

**Using Keystores (Recommended for Production):**

Keystores encrypt your private keys and are much more secure than plain text private keys in `.env` files.

1. **Import your private key into a keystore:**
   ```bash
   # Interactive password prompt (recommended)
   cast wallet import --private-key <RAW_PRIVATE_KEY> <ACCOUNT_NAME>
   # Enter a strong password when prompted
   ```

2. **Use keystore in deployment commands:**
   ```bash
   # Canonical one-shot stack. FOUNDRY_PROFILE=deploy required.
   # Precondition: make check-deploy green on this commit. See docs/relaunch/CUTOVER_RUNBOOK.md.
   REAL_DEPLOYMENT=true \
   INITIAL_SWAPPER=<bot-eoa> \
   FOUNDRY_PROFILE=deploy \
   forge script script/DeployFinal.s.sol:DeployFinal \
     --rpc-url $RSK_MAINNET_RPC_URL \
     --account <deployer> \
     --broadcast \
     --verify \
     --verifier blockscout \
     --verifier-url $BLOCKSCOUT_API_URL \
     --legacy
   ```

**Using Hardware Wallets (Most Secure):**

For maximum security, use a Ledger or Trezor hardware wallet:

```bash
# With Ledger — FOUNDRY_PROFILE=deploy required, see below
FOUNDRY_PROFILE=deploy \
forge script script/DeployMocSwaps.s.sol \
  --rpc-url $RSK_TESTNET_RPC_URL \
  --ledger \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url $BLOCKSCOUT_API_URL \
  --legacy

# With Trezor — FOUNDRY_PROFILE=deploy required, see below
FOUNDRY_PROFILE=deploy \
forge script script/DeployMocSwaps.s.sol \
  --rpc-url $RSK_TESTNET_RPC_URL \
  --trezor \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url $BLOCKSCOUT_API_URL \
  --legacy
```

#### Deployment Steps

1. Set up environment variables in `.env` (RPC URLs, Blockscout). For the canonical stack:

```bash
export REAL_DEPLOYMENT=true
export INITIAL_SWAPPER=<production-bot-eoa>
export FOUNDRY_PROFILE=deploy
```

2. Deploy on Rootstock **mainnet** (fail-closed: `DeployFinal.run()` rejects non-mainnet and incomplete maps):

```bash
REAL_DEPLOYMENT=true \
INITIAL_SWAPPER=<bot-eoa> \
FOUNDRY_PROFILE=deploy \
forge script script/DeployFinal.s.sol:DeployFinal \
  --rpc-url $RSK_MAINNET_RPC_URL \
  --account <deployer-eoa> \
  --broadcast --legacy \
  --verify --verifier blockscout --verifier-url $BLOCKSCOUT_API_URL
```

Full checklist: [`docs/relaunch/CUTOVER_RUNBOOK.md`](./docs/relaunch/CUTOVER_RUNBOOK.md).
Lane scripts (`DeployMocSwaps`, `DeployDexSwaps`, add-ons) remain for local/fork tests and incremental
additions; they are not the one-shot cutover path.

#### Ownership after deploy

Foundry always broadcasts from an EOA (`--account` / `--ledger`). A Safe cannot sign that transaction.

Live owner and fee-collector addresses live in `script/Constants.sol`:

| Network | Owner | Fee collector |
|---|---|---|
| Testnet | `TESTNET_OWNER` (the funded EOA that broadcasts) | same EOA |
| Mainnet | `MAINNET_OWNER` (the BitChill Safe) | `MAINNET_FEE_COLLECTOR` |

**Testnet.** Broadcast from `TESTNET_OWNER`. The script reverts *before* any `CREATE` if a different key is used. After the script, that EOA already owns every contract and `pendingOwner` is zero. No `acceptOwnership`.

**Mainnet.** Broadcast from an EOA, **not** the Safe. The script:

1. Constructs `OperationsAdmin`, `DcaManager`, and every handler with the EOA as owner (so `registerRoute` / `assignTokenHandler` succeed in the same broadcast).
2. Calls `transferOwnership(MAINNET_OWNER)` on each of those contracts. That only *proposes*.

Then, from the Safe UI (one call per contract), send `acceptOwnership()`. Until those accepts land, the deploying EOA can still govern and can propose a different address if the Safe hex was wrong. After accept, the Safe owns `OperationsAdmin`, `DcaManager`, and every handler.

Add-on scripts (`DeployIdleHandler`, `DeployLayerBankHandler`, `DeployUsdrifHandler`) revert if `pendingOwner` is set on `OperationsAdmin` or `DcaManager` — wait until the Safe has accepted, then run them.

**USDT0 / USDRIF add-on (`DeployUsdrifHandler`).** This is the live add-on path against an existing `DcaManager`. On mainnet the Safe already owns `OperationsAdmin`, so the Foundry EOA hits the non-owner branch: it deploys the handler (constructor self-allowlists the initial path), logs, and returns **without** `assignTokenHandler` and **without** `setTokenMinPurchaseAmount`. That is fail-closed until the Safe assigns the handler **and** sets the per-token min (there is no protocol-wide default). After the script, from the Safe, **in this order**:

1. `operationsAdmin.registerRoute(1, true)` **only if** `getRouteClass(1)` is still `Unregistered`. A second `registerRoute` reverts `RouteAlreadyRegistered` (LayerBank is already on the dex map after the USDRIF add-on).
2. Read `handler.getSwapPath()` and verify it exactly matches the intended stablecoin / intermediate pools / WRBTC route. The constructor already allowlisted that path; this is the human checkpoint before assignment.
3. `dcaManager.setTokenMinPurchaseAmount(token, min)` — USDRIF `25 ether`, USDT0 `25000000` (`25e6`). Do not skip this step.
4. `operationsAdmin.assignTokenHandler(token, 1, handler)`. Set the min first so the token is never routable while create still reverts `TokenMinPurchaseAmountNotSet`.

**Compromised swapper.** Revoke the swapper key **before** revoking any path. A still-allowlisted compromised key can front-run each `setPurchasePathAllowed(..., false)` by re-activating that path. Order is mandatory: `revokeSwapper` → handler owner or remaining swapper `setPurchasePath` to the preferred approved path if needed → then handler owner revokes obsolete paths. Swapper revocation alone is not a routing kill switch.

`DeployDexSwaps` live full-stack sets that min in the same broadcast because that script owns the new admin. The add-on does not.

`DeployMocAndUniswap` is a local/fork comparison harness (two independent stacks) and **reverts** on
`REAL_DEPLOYMENT=true`. The canonical one-shot live script is **`DeployFinal`**: idle / LayerBank /
Sovryn DOC (MoC) plus idle / LayerBank for USDRIF and USDT0 (Uniswap) on a single `OperationsAdmin` /
`DcaManager`. See [`docs/relaunch/CUTOVER_RUNBOOK.md`](./docs/relaunch/CUTOVER_RUNBOOK.md).

Later ownership changes (new Safe, recovered wallet) are the same two steps: current owner `transferOwnership(new)`, incoming owner `acceptOwnership()`. `renounceOwnership` always reverts.

### Compilation profile for deployment

The relaunch deployment profile is **`[profile.deploy]`** (`FOUNDRY_PROFILE=deploy`): solc `0.8.36`,
Cancun, `optimizer = true`, `optimizer_runs = 200`, and — unlike every other profile in this repo —
`via_ir = true`, compiled across `src/`, `test/`, and `script/` with exactly one file excluded
(`test/ai-generated/unit/layerbank/LayerBankErc20HandlerDexTest.t.sol`; see `foundry.toml`). Every
broadcast command above **requires**
`FOUNDRY_PROFILE=deploy` in its environment — `forge script` reads compiler settings from whichever
profile is active, and without it a broadcast silently compiles and deploys the `[profile.default]`
(no-IR) artifact instead, which is not what `make check-deploy` validated.

**Precondition for any real broadcast: run `make check-deploy` green on the exact commit being
deployed first.** That target compiles `src/`, `test/`, and `script/` under `via_ir = true` and runs the
full configured test matrix against that exact bytecode — a test's `new DcaManager(...)` deploys the identical
artifact `forge script` would broadcast, so a passing `check-deploy` is the only proof this bytecode
passes the suite. Do not broadcast on a commit `check-deploy` has not been run against.

The rationale and the two test-only compiler carve-outs are recorded in
[`R60-src-only-via-ir.md`](./docs/relaunch/R60-src-only-via-ir.md). An optimizer-on/no-IR artifact has
already been deployed and verified on Rootstock testnet, but the exact `via_ir=true` deploy profile
still needs a representative testnet deployment and Blockscout verification before mainnet. Treat that
as an outstanding release gate, not as evidence supplied by Anvil fork tests.

## Dependency Management

This project uses Git submodules for dependency management:

- OpenZeppelin Contracts **v5.7.0**

For contract addresses after cutover, publish from the `DeployFinal` log; historical lists may live in [ADDRESSES.md](./ADDRESSES.md).

## License

- `src/`: [BUSL-1.1](./LICENSE) (Additional Use Grant for non-production use; Change License `GPL-2.0-or-later`)
- `script/` / `test/`: MIT
- See [R72](./docs/relaunch/R72-licensing.md) and `SECURITY.md`.

## Contact
For audit-related inquiries or security concerns, please contact:
- Smart Contract Developer: [Antonio Rodríguez-Ynyesto](https://www.linkedin.com/in/antonio-maria-rodriguez-ynyesto-sanchez/)

## Disclaimer

Smart contracts involve risk. The historical 2025 reviews and the relaunch test suite do not guarantee
safety. Always perform your own diligence before interacting with the protocol.
