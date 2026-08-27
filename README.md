# BitChill - Smart Contracts

## Introduction
BitChill is a decentralized protocol on Rootstock that enables users to automate their BTC purchases with Dollar-Cost Averaging (DCA) strategies. The protocol currently supports stablecoins DOC and USDRIF and integrates with Tropykus and Sovryn lending protocols, allowing users to create, update, and delete DCA schedules while earning yield on their deposits.

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
   - Stores the stablecoins deposited by the users
   - Handles deposits and withdrawals of stablecoins

3. **Lending Integration**
   - `TokenLending` abstract contract
      - Manages conversion of balances from stablecoins to lending tokens and viceversa
   - Supports multiple lending protocols (Tropykus, Sovryn)
   - `TropykusErc20Handler` and `SovrynErc20Handler`
      - Implement deposits and withdrawals overriding `TokenHandler` to deposit to and withdraw from lending protocols
      - Handle withdrawal of accrued interests

4. **Purchase Methods**
   - `PurchaseMoc`: Direct redemption through Money on Chain (for DOC)
   - `PurchaseUniswap`: Swaps through Uniswap V3 (for other stablecoins)
   - Both implementations tested and optimized for their specific use cases

### Architecture Design Considerations

The protocol was designed with extensibility in mind, supporting multiple purchase methods and stablecoins:

1. Money on Chain (MoC) for DOC:
   - Better gas efficiency overall (slightly worse for small purchases)
   - More stable pricing (primary market)
   - Direct redemption mechanism
   - No slippage

2. Uniswap V3 for other stablecoins:
   - Flexible integration for any ERC20 stablecoin
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
   - Automatic yield generation on deposits

2. **Token Management**
   - Support for multiple stablecoins (DOC, USDRIF)
   - Integration with lending protocols
   - Interest accrual and withdrawal
   - Fee management system

3. **Security Features**
   - Access control for all critical functions
   - Reentrancy protection
   - Input validation and error handling

4. **Batch Processing**
   - Gas-efficient batch purchases
   - Optimized for multiple users

## Security Considerations

### Access Control
- Role-based access control for all critical functions
- Owner and admin roles with specific permissions
- Swapper role for purchase operations
- DCA manager contract as central authority

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
- Rootstock-compatible compiler version (v0.8.36, EVM cancun)
- OpenZeppelin Contracts v4.9.3
- Money on Chain Protocol (for DOC)
- Uniswap V3 Protocol (for other stablecoins)

### Key Security Assumptions
1. Money on Chain protocol security (for DOC)
2. Uniswap V3 protocol security (for other stablecoins)
3. Token contract integrity
4. Lending protocol reliability

### Known Limitations
1. Gas efficiency trade-offs for extensibility
2. Potential for future optimization
3. Dependencies on external protocols

### Audit and Testing

BitChill's smart-contracts have undergone a manual audit by **[Ivan Fitro](https://github.com/IvanFitro)**.  

Also, we used an extensive automation pipeline:

* 100 % branch-level test-coverage on core contracts, with > 94 % line coverage overall.  
  – Hundreds of AI-generated unit tests exercise edge-cases that were missed in the original hand-written suite.
* Property-based fuzzing & invariant testing.

Despite these measures **no audit or test-suite can guarantee absolute safety**. You should always perform your own due-diligence and only risk funds you can afford to lose.

## Getting Started

### Prerequisites
- Rust
- Foundry
- Rootstock RPC access

### Installation
```bash
git clone git@github.com:BitChillRSK/DCAdApp.git
cd bitchill-contracts
git checkout smart-contracts
./setup.sh
```

### Testing
```bash
# Local done-gate (build + moc-none + moc-layerbank + moc-sovryn + dex-sovryn + invariants-sovryn)
make check

# Run tests with DOC and idle funds (index 0)
make moc-none

# Run tests with DOC and LayerBank (index 1)
make moc-layerbank

# Run tests with DOC and Sovryn (index 2)
make moc-sovryn

# Legacy Tropykus mocks (not on the production map)
make moc-tropykus

# Run tests with USDRIF and Tropykus
STABLECOIN_TYPE=USDRIF make dex-tropykus

# Run tests with USDRIF and Sovryn
STABLECOIN_TYPE=USDRIF make dex-sovryn

# Run specific test file with custom parameters
STABLECOIN_TYPE=USDRIF SWAP_TYPE=dexSwaps LENDING_PROTOCOL=tropykus forge test --match-path test/unit/DcaDappTest.t.sol -vvv

# -------------------------------
# Invariant & Fuzz Testing
# -------------------------------
# Foundry-based fuzzing and invariants live in `test/ai-generated/fuzz`.  A detailed guide
# is available in [README_INVARIANTS.md](test/ai-generated//fuzz/README_INVARIANTS.md).
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
   forge script script/DeployMocSwaps.s.sol \
     --rpc-url $RSK_TESTNET_RPC_URL \
     --account dev_wallet \
     --broadcast \
     --verify \
     --verifier blockscout \
     --verifier-url $BLOCKSCOUT_API_URL \
     --legacy

   # Enter password when prompted
   ```

**Using Hardware Wallets (Most Secure):**

For maximum security, use a Ledger or Trezor hardware wallet:

```bash
# With Ledger
forge script script/DeployMocSwaps.s.sol \
  --rpc-url $RSK_TESTNET_RPC_URL \
  --ledger \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url $BLOCKSCOUT_API_URL \
  --legacy

# With Trezor
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

1. Set up your environment variables in `.env`:
```bash
# Required variables
RSK_TESTNET_RPC_URL=your_rsk_testnet_rpc_url
BLOCKSCOUT_API_KEY=your_blockscout_api_key
BLOCKSCOUT_API_URL=https://rootstock-testnet.blockscout.com/api

# Deployment configuration
export SWAP_TYPE=mocSwaps  # for DOC, or dexSwaps for other stablecoins
export STABLECOIN_TYPE=DOC  # or USDRIF
export REAL_DEPLOYMENT=true  # Set to true for actual deployment on a live network
```

2. Deploy the contracts:
```bash
# Deploy to Rootstock Testnet
REAL_DEPLOYMENT=true \
forge script script/DeployMocSwaps.s.sol \
  --rpc-url $RSK_TESTNET_RPC_URL \
  --account dev_wallet \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url $BLOCKSCOUT_API_URL \
  --legacy

# Deploy to Rootstock Mainnet
REAL_DEPLOYMENT=true \
forge script script/DeployMocSwaps.s.sol \
  --rpc-url $RSK_MAINNET_RPC_URL \
  --account dev_wallet \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url $BLOCKSCOUT_API_URL \
  --legacy
```

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

`DeployMocAndUniswap` is a local/fork comparison harness (two independent stacks) and **reverts** on `REAL_DEPLOYMENT=true`. It is not the live deploy. A later one-shot live script — idle, Sovryn DOC, LayerBank DOC, LayerBank USDRIF, LayerBank USDT0 on a single `OperationsAdmin` / `DcaManager` — belongs after the production map is final (R36 / R37). Until then use `DeployMocSwaps` / `DeployDexSwaps` plus the add-ons.

Later ownership changes (new Safe, recovered wallet) are the same two steps: current owner `transferOwnership(new)`, incoming owner `acceptOwnership()`. `renounceOwnership` always reverts.

### Compilation profile for deployment
Before deploying on-chain, compile using the dedicated `deploy` profile that activates the Yul Intermediate Representation (via_IR) pipeline (see `foundry.toml`).

```bash
# One-off compilation
FOUNDRY_PROFILE=deploy forge build

# Or run any script / test under the deploy profile
FOUNDRY_PROFILE=deploy forge script ...
```

This profile sets `via_ir = true` and `optimizer_runs = 200`, producing smaller, cheaper byte-code, under the 24,576-byte limit (as per EIP-170). 

*Warning*: viaIR compilation might cause unexpected results. Be sure to run the full test suite again before deploying the contracts on Rootstock mainnet!

## Dependency Management

This project uses Git submodules for dependency management. The following dependencies are included:

- OpenZeppelin Contracts v4.9.3
- Uniswap V3 Core v1.0.0
- Uniswap V3 Periphery v1.3.0
- Uniswap Swap Router Contracts v1.3.0

Uniswap V3 sources still declare `pragma solidity =0.7.6`. Local builds and CI patch those pragmas so they compile with first-party solc 0.8.36. Details: [DEPENDENCY_MODIFICATIONS.md](./DEPENDENCY_MODIFICATIONS.md).

For a complete list of contract addresses used in the protocol (including both mainnet and testnet), please refer to [ADDRESSES.md](./ADDRESSES.md).

## Contact
For audit-related inquiries or security concerns, please contact:
- Smart Contract Developer: [Antonio Rodríguez-Ynyesto](https://www.linkedin.com/in/antonio-maria-rodriguez-ynyesto-sanchez/)

## Disclaimer
This protocol has been audited but could still have bugs. Use at your own risk. Always perform due diligence before interacting with smart contracts.

