// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

// Re-exports every deploy constant, so a test never needs to import `script/Constants.sol` as well.
// Constants declared below are test-only: nothing under `script/` may see them.
import "../script/Constants.sol";

// Legacy Tropykus route index. Test-only on purpose: nothing under `script/` may name it, so no
// deploy path can register or assign a Tropykus route by accident. Index 4 stays burned — never
// reuse it for another venue. The shared harness registers every index on one `OperationsAdmin`,
// which is why this is 4 rather than colliding with `LAYERBANK_INDEX`.
uint256 constant TROPYKUS_INDEX = 4;

// A route index no lane ever registers, so `getTokenHandler` returns `address(0)` for every token
// on it. Used to prove the withdraw-all pair loops skip an unassigned pair instead of reverting.
uint256 constant UNREGISTERED_ROUTE_INDEX = 999;

// Harness account labels. `OWNER_STRING` and `FEE_COLLECTOR_STRING` are not here: `DeployBase`
// derives the deployed owner and fee collector from those, so they belong with the deploy defaults.
string constant USER_STRING = "user";
string constant ADMIN_STRING = "ADMIN";
string constant SWAPPER_STRING = "SWAPPER";

// Assertion tolerance for purchase comparisons. Deliberately NOT derived from
// `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT`: it is how close the payout must sit to the oracle price for
// the test to accept it, not what the router enforces. On a live-pool fork a fill between the
// swap-time floor and this tolerance fails the assertion rather than reverting in the router.
uint256 constant MAX_SLIPPAGE_PERCENT = 0.005 ether; // 0.5% — MoC redeems at the oracle price
// Uniswap also pays the pool's LP fee and price impact. Measured ~0.73% off oracle on the live USDRIF
// path at block 9198813; 1.5% leaves room for pool movement without reaching the 3% swap-time floor.
uint256 constant DEX_MAX_SLIPPAGE_PERCENT = 0.015 ether; // 1.5%

// Share-rate scale a test reproduces when it recomputes a handler's share math. Each handler
// declares its own `EXCHANGE_RATE_DECIMALS` (Sovryn and Tropykus 1e18, LayerBank RAY 1e27); read
// the handler's constant when the assertion is about the handler, and use this only where the test
// is 1e18-denominated by construction.
uint256 constant EXCHANGE_RATE_DECIMALS = 1e18; // Valid for DOC and USDRIF in both Tropykus and Sovryn

// Fee-rate denominator mirrored by `TestsHelper`'s independent fee calculation. `FeeHandler`
// declares its own copy on purpose: the test must not compute the expected fee from the same
// symbol the implementation uses.
uint256 constant FEE_PERCENTAGE_DIVISOR = 10_000;

// Token holders on mainnet with significant balances (for fork testing)
address constant DOC_HOLDER = 0x65d189e839aF28B78567bD7255f3f796495141bc; // Large DOC holder on RSK mainnet
address constant USDRIF_HOLDER = 0xD07d569322a93a47B62D71203e21f0AFf8246099; // Large USDRIF holder on RSK mainnet
// If these get rid of their holdings, we can look for other holders at
// https://rootstock.blockscout.com/token/0x3A15461d8AE0f0Fb5fA2629e9dA7D66A794a6E37?tab=holders
// Token holders on testnet with significant balances (for fork testing)
address constant DOC_HOLDER_TESTNET = 0x53Ec0aF115619c536480C95Dec4a065e27E6419F; // Large DOC holder on RSK testnet
address constant USDRIF_HOLDER_TESTNET = 0xe38C86970543173D334b828485D8bc48d19Ff701; // Large USDRIF holder on RSK testnet
