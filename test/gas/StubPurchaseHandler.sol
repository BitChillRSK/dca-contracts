// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
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
 *      `ITokenHandler` and must not answer `ITokenLending`, which idle routes reject.
 */
contract StubPurchaseHandler is IERC165, ITokenHandler, IPurchaseRbtc {
    uint256 public deposits;
    uint256 public rowsBought;

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function depositToken(address, uint256 amount) external override {
        deposits += amount;
    }

    function withdrawToken(address, uint256 amount) external override returns (uint256) {
        return amount;
    }

    function batchBuyRbtc(address[] memory buyers, uint64[] memory, uint256[] memory, uint256) external override {
        rowsBought += buyers.length;
    }

    function withdrawAccumulatedRbtc(address) external override {}

    function getAccumulatedRbtcBalance(address) external pure override returns (uint256) {
        return 0;
    }
}
