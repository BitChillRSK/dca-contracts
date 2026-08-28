// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

// Import main constants from script
import "../script/Constants.sol";

// Legacy Tropykus route index. Test-only on purpose: nothing under `script/` may name it, so no
// deploy path can register or assign a Tropykus route by accident. Index 4 stays burned — never
// reuse it for another venue. The shared harness registers every index on one `OperationsAdmin`,
// which is why this is 4 rather than colliding with `LAYERBANK_INDEX`.
uint256 constant TROPYKUS_INDEX = 4;

// A route index no lane ever registers, so `getTokenHandler` returns `address(0)` for every token
// on it. Used to prove the withdraw-all pair loops skip an unassigned pair instead of reverting.
uint256 constant UNREGISTERED_ROUTE_INDEX = 999;


// Token holders on testnet with significant balances (for fork testing)
address constant DOC_HOLDER_TEST = 0x53Ec0aF115619c536480C95Dec4a065e27E6419F; // Large DOC holder on RSK testnet
address constant USDRIF_HOLDER_TEST = 0xe38C86970543173D334b828485D8bc48d19Ff701; // Large USDRIF holder on RSK testnet
