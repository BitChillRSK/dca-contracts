//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {ILendingHandler} from "../../src/interfaces/ILendingHandler.sol";
import "../Constants.sol";

contract DummyERC165Contract {
    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IDcaManager).interfaceId; // Check against an interface different from TokenHandler's
    }
}

/// @dev ERC-165 `ITokenHandler` stub for OperationsAdmin assignment tests. Not a funded handler.
///      Reports the stablecoin and DcaManager it was built for, which `assignHandler` checks.
contract DummyTokenHandler {
    address public immutable i_stablecoin;
    address public immutable i_dcaManager;

    constructor(address stablecoin, address dcaManager) {
        i_stablecoin = stablecoin;
        i_dcaManager = dcaManager;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId;
    }
}

/// @dev ERC-165 `ITokenHandler` + `ILendingHandler` stub for lending-route assignment tests.
///      Reports the stablecoin and DcaManager it was built for, which `assignHandler` checks.
contract DummyLendingHandler {
    address public immutable i_stablecoin;
    address public immutable i_dcaManager;

    constructor(address stablecoin, address dcaManager) {
        i_stablecoin = stablecoin;
        i_dcaManager = dcaManager;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId || interfaceId == type(ILendingHandler).interfaceId;
    }
}

/// @dev Advertises `ITokenHandler` but has no `i_stablecoin()`, so assignment cannot check its stablecoin.
contract DummyTokenHandlerWithoutStablecoin {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId;
    }
}

contract FeeCalculator {
    uint256 internal s_minFeeRate = MIN_FEE_RATE;
    uint256 internal s_maxFeeRate = MAX_FEE_RATE_TEST; // Use test fee rate for testing
    uint256 internal s_feePurchaseLowerBound = FEE_PURCHASE_LOWER_BOUND;

    function calculateFee(uint256 x) external view returns (uint256) {
        if (x <= s_feePurchaseLowerBound) return x * s_maxFeeRate / BPS_DENOMINATOR;
        uint256 discountNumerator =
            (s_maxFeeRate - s_minFeeRate) * (x - s_feePurchaseLowerBound) * (x - s_feePurchaseLowerBound);
        uint256 discount = discountNumerator / x + (discountNumerator % x == 0 ? 0 : 1);
        return (s_maxFeeRate * x - discount) / BPS_DENOMINATOR;
    }
}
