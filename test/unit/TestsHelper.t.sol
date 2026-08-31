//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {ITokenLending} from "../../src/interfaces/ITokenLending.sol";
import "../Constants.sol";

contract DummyERC165Contract {
    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IDcaManager).interfaceId; // Check against an interface different from TokenHandler's
    }
}

/// @dev ERC-165 `ITokenHandler` stub for OperationsAdmin assignment tests. Not a funded handler.
contract DummyTokenHandler {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId;
    }
}

/// @dev ERC-165 `ITokenHandler` + `ITokenLending` stub for lending-route assignment tests.
contract DummyLendingHandler {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId
            || interfaceId == type(ITokenLending).interfaceId;
    }
}

/// @dev Configurable `getSwapPath` target for OperationsAdmin Dex-path tests.
contract DummyDexPathHandler {
    bytes internal s_path;
    bool internal s_revert;

    constructor(bytes memory path) {
        s_path = path;
    }

    function getSwapPath() external view returns (bytes memory) {
        if (s_revert) revert("DummyDexPathHandler: revert");
        return s_path;
    }

    function setPath(bytes memory path) external {
        s_path = path;
    }

    function setRevert(bool shouldRevert) external {
        s_revert = shouldRevert;
    }
}

/// @dev Selector exists but the return type is not `bytes`, so ABI-decode fails.
contract DummyDexPathReturnsUint {
    function getSwapPath() external pure returns (uint256) {
        return 1;
    }
}

contract FeeCalculator {
    uint256 internal s_minFeeRate = MIN_FEE_RATE;
    uint256 internal s_maxFeeRate = MAX_FEE_RATE_TEST; // Use test fee rate for testing
    uint256 internal s_feePurchaseLowerBound = FEE_PURCHASE_LOWER_BOUND;
    uint256 internal s_feePurchaseUpperBound = FEE_PURCHASE_UPPER_BOUND;

    function calculateFee(uint256 purchaseAmount) external view returns (uint256) {

        if (s_minFeeRate == s_maxFeeRate) {
            return purchaseAmount * s_minFeeRate / FEE_PERCENTAGE_DIVISOR;
        }

        uint256 feeRate;

        if (purchaseAmount >= s_feePurchaseLowerBound) {
            feeRate = s_minFeeRate;
        } else if (purchaseAmount <= s_feePurchaseLowerBound) {
            feeRate = s_maxFeeRate;
        } else {
            // Calculate the linear fee rate
            feeRate = s_maxFeeRate
                - ((purchaseAmount - s_feePurchaseLowerBound) * (s_maxFeeRate - s_minFeeRate))
                    / (s_feePurchaseUpperBound - s_feePurchaseLowerBound);
        }
        return purchaseAmount * feeRate / FEE_PERCENTAGE_DIVISOR;
    }
}
