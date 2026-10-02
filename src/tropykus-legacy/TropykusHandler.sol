// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LendingHandler} from "../LendingHandler.sol";
import {IkToken} from "./IkToken.sol";
import {ITropykusHandler} from "./ITropykusHandler.sol";

/**
 * @title TropykusHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Tropykus adapter: Compound-style kToken mint/redeem. Share accounting lives on LendingHandler.
 * @dev Test-only adapter, excluded from production deployment; local and fork lanes retain coverage.
 */
abstract contract TropykusHandler is LendingHandler, ITropykusHandler {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tropykus kToken exchange-rate scale (1e18).
     * @return Always `1e18` for this protocol.
     */
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18;

    /// @notice Tropykus kToken this handler mints and redeems.
    IkToken public immutable i_kToken;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param stablecoin The ERC20 stablecoin this handler lends.
     * @param kToken Tropykus kToken for that stablecoin.
     */
    constructor(address dcaManager, address stablecoin, address kToken)
        LendingHandler(dcaManager, stablecoin, EXCHANGE_RATE_DECIMALS)
    {
        i_kToken = IkToken(kToken);
        if (i_kToken.underlying() != stablecoin) {
            revert TropykusHandler__UnderlyingMismatch();
        }
        _approveLendingSpender();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _exchangeRate() internal override returns (uint256) {
        return i_kToken.exchangeRateCurrent();
    }

    function _viewExchangeRate() internal view override returns (uint256) {
        return i_kToken.exchangeRateStored();
    }

    function _lendingSpender() internal view override returns (address) {
        return address(i_kToken);
    }

    /// @dev Mint only; the base credits the measured kToken gain, never `mint()`'s return value.
    function _protocolDeposit(uint256 stablecoinAmount) internal override {
        if (i_kToken.mint(stablecoinAmount) != 0) revert LendingHandler__LendingProtocolDepositFailed();
    }

    /**
     * @dev Redeem kTokens onto this contract. Burns the booked share count. Only the Compound
     *      return code is raised here; the base measures cash and kToken deltas.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256) internal override {
        uint256 result = i_kToken.redeem(sharesAmount);
        if (result != 0) revert TropykusHandler__LendingProtocolRedeemFailed(result);
    }

    function _receiptSharesBalance() internal override returns (uint256) {
        return i_kToken.balanceOf(address(this));
    }
}
