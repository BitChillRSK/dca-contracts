// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Protocol configuration
// @notice the fee rate and bound constants carry IFeeHandler.FeeSettings' widths so deploy scripts
// and tests can build that struct without a cast.
uint256 constant MIN_PURCHASE_AMOUNT = 25 ether; // at least 25 DOC on each purchase
uint16 constant MIN_FEE_RATE = 100;
uint16 constant MAX_FEE_RATE_TEST = 200; // 2% for testing - allows for better fee range testing
uint16 constant MAX_FEE_RATE_PRODUCTION = 100; // 1% flat rate for production (same as MIN_FEE_RATE for flat fee)
uint128 constant FEE_PURCHASE_LOWER_BOUND = 1000 ether; // 1000 DOC
uint128 constant FEE_PURCHASE_UPPER_BOUND = 100_000 ether; // 100,000 DOC
uint256 constant FEE_PERCENTAGE_DIVISOR = 10_000;
uint256 constant MIN_PURCHASE_PERIOD = 1 days; // Default to at most one purchase each day
uint256 constant MAX_SCHEDULES_PER_TOKEN = 10; // Default to a maximum of 10 DCA schedules per token

// Chain IDs
uint256 constant ANVIL_CHAIN_ID = 31337;
uint256 constant RSK_MAINNET_CHAIN_ID = 30;
uint256 constant RSK_TESTNET_CHAIN_ID = 31;

// Live governance. Foundry broadcasts from an EOA (`forge script --account` / `--ledger`).
// Testnet: that EOA is the owner. Mainnet: the EOA deploys and proposes the Safe, which must
// `acceptOwnership` on each contract. Do not set MAINNET_OWNER as `initialOwner` in the same
// script that calls `onlyOwner` setup — a Safe cannot sign a Foundry broadcast.
address constant TESTNET_OWNER = 0x31e0FacEa072EE621f22971DF5bAE3a1317E41A4;
address constant MAINNET_OWNER = 0xdeAbdc410aB7B0f1Da830A6b355B5b938208315f;
address constant TESTNET_FEE_COLLECTOR = TESTNET_OWNER;
address constant MAINNET_FEE_COLLECTOR = 0x3caB92C050514A0368D71815CAc42ad746350F16;

// Production route indexes (fresh relaunch map) and LENDING_PROTOCOL env strings.
// `DeployMocSwaps` and `DeployDexSwaps` each deploy their own `OperationsAdmin`, so the MoC
// map below and the dex map are independent; an index means nothing across the two admins.
uint256 constant IDLE_INDEX = 0; // constructor pre-registers this as idle
string constant NONE_STRING = "none";
string constant LAYERBANK_STRING = "layerbank";
uint256 constant LAYERBANK_INDEX = 1;
string constant SOVRYN_STRING = "sovryn";
uint256 constant SOVRYN_INDEX = 2;
uint256 constant RESERVED_MOC_LENDING_INDEX = 3; // reserved for future MoC lending; not assigned in this PR

// Legacy Tropykus. Test-only: no deploy script builds or registers a Tropykus handler on a live
// network, on either map, and index 4 is burned so it is never reinterpreted as another venue.
// The index constant lives in `test/Constants.sol`, which is out of scope for every `script/`
// file — so a script that tries to name a Tropykus route fails to compile rather than failing
// review. `TROPYKUS_STRING` stays here: `MocHelperConfig` / `DexHelperConfig` / `DeployBase`
// read it to select Tropykus mocks for the local `LENDING_PROTOCOL=tropykus` lane, and none of
// them uses the index. Only the index can land in production storage.
string constant TROPYKUS_STRING = "tropykus";

// Default configurations
string constant DOC_STRING = "DOC"; // Unset STABLECOIN_TYPE falls back to this in `_stablecoinType()`.
string constant USDRIF_STRING = "USDRIF";
string constant USDT0_STRING = "USDT0";
// Swap-time oracle floor. Deliberately loose: the swapper's per-batch `minRbtcOut` is the operational
// bound, and this is what holds when that minimum is absent, stale, or hostile. Derived from the live
// quote table (`make probe-dex-quote-floor`, block 9198813): the worst realistic-size fill was LayerBank
// USDRIF at 99.27% of oracle for a $1,000 batch, so 97% leaves ~227 bps for peg drift, oracle drift, and
// pool movement between quote and inclusion, while capping a compromised-swapper loss at 3%.
uint256 constant DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT = 0.97 ether; // 97%
// The wall the owner cannot cross in one transaction when widening the floor above.
uint256 constant DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK = 0.95 ether; // 95%
// Assertion tolerance for purchase comparisons. Deliberately NOT derived from the floor above: it is how
// close the mock router's payout must sit to the oracle price, not what the router enforces. On a live-pool
// fork a fill between the floor and this tolerance fails the assertion rather than reverting in the router.
uint256 constant MAX_SLIPPAGE_PERCENT = 0.005 ether; // 0.5%
uint256 constant EXCHANGE_RATE_DECIMALS = 1e18; // Valid for DOC and USDRIF in both Tropykus and Sovryn

// USDT0 is 6 decimals. Do not pass MIN_PURCHASE_AMOUNT / FEE_PURCHASE_* (18-decimal DOC/USDRIF
// units) into a USDT0 handler — that would make the min ~25 trillion USDT0 and put every real
// purchase at the max fee band. Live/mainnet USDT0 deploy paths use these magnitudes.
uint256 constant USDT0_MIN_PURCHASE_AMOUNT = 25e6;
uint128 constant USDT0_FEE_PURCHASE_LOWER_BOUND = 1000e6;
uint128 constant USDT0_FEE_PURCHASE_UPPER_BOUND = 100_000e6;

// Mainnet LayerBank aTokens on Pool `0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9` (looked up 2026-08-28).
address constant USDT0_MAINNET = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
address constant LAYERBANK_USDRIF_ATOKEN = 0xc96fBD12bE56Dd565b258d243344bCf792A51128; // lRooUSDRIF
address constant LAYERBANK_USDT0_ATOKEN = 0x6bE7d4cfCe825b106aa88F6916A412c5af230Ec0; // lRooUSDT0


/*//////////////////////////////////////////////////////////////
                        TESTS CONSTANTS
//////////////////////////////////////////////////////////////*/

// Test account names
string constant OWNER_STRING = "owner";
string constant USER_STRING = "user";
string constant ADMIN_STRING = "ADMIN";
string constant SWAPPER_STRING = "SWAPPER";
string constant FEE_COLLECTOR_STRING = "feeCollector";

// Test values
uint256 constant BTC_PRICE = 50_000; // 1 BTC = 50,000 DOC

// Token holders on mainnet with significant balances (for fork testing)
address constant DOC_HOLDER = 0x65d189e839aF28B78567bD7255f3f796495141bc; // Large DOC holder on RSK mainnet
address constant USDRIF_HOLDER = 0xD07d569322a93a47B62D71203e21f0AFf8246099; // Large USDRIF holder on RSK mainnet 
// If these get rid of their holdings, we can look for other holders at 
// https://rootstock.blockscout.com/token/0x3A15461d8AE0f0Fb5fA2629e9dA7D66A794a6E37?tab=holders
// Token holders on testnet with significant balances (for fork testing)
address constant DOC_HOLDER_TESTNET = 0x53Ec0aF115619c536480C95Dec4a065e27E6419F; // Large DOC holder on RSK testnet
address constant USDRIF_HOLDER_TESTNET = 0xe38C86970543173D334b828485D8bc48d19Ff701; // Large USDRIF holder on RSK testnet