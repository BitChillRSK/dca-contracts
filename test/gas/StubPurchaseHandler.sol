// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @notice Idle-route handler stub whose every entry point costs the same on both designs under test.
 * @dev Exists so `batchBuyRbtc`'s measured gas is the manager's own bookkeeping plus one constant
 *      handler call, rather than the venue's. It moves no tokens: R64 measures how a schedule is
 *      addressed and how a batch is encoded, and a real ERC-20 leg would bury that difference under
 *      transfer and lending-share costs identical on both sides. `deposits` records what the manager
 *      asked for so a benchmark can assert the manager actually ran the deposit path.
 *
 *      Passes `OperationsAdmin.assignTokenHandler`'s ERC-165 gate for an idle route: it answers
 *      `ITokenHandler` and must not answer `ITokenLending`, which idle routes reject. It also reports
 *      the token it is assigned for, which that function checks against its `token` argument.
 */
contract StubPurchaseHandler is IERC165, ITokenHandler, IPurchaseRbtc {
    IERC20 public immutable i_stableToken;
    uint256 public deposits;
    uint256 public rowsBought;

    constructor(address stableToken) {
        i_stableToken = IERC20(stableToken);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function depositToken(address, uint256 amount) external override {
        deposits += amount;
    }

    function withdrawToken(address, uint256 amount) external override returns (uint256) {
        return amount;
    }

    function batchBuyRbtc(address[] calldata buyers, uint64[] calldata, uint256[] calldata, uint256) external override {
        rowsBought += buyers.length;
    }

    function withdrawAccumulatedRbtc(address) external override {}

    function getAccumulatedRbtcBalance(address) external pure override returns (uint256) {
        return 0;
    }
}
