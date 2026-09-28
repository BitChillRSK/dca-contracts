// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LendingHandler} from "../LendingHandler.sol";
import {IiSusdToken} from "./IiSusdToken.sol";

/**
 * @title SovrynHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn adapter: iSUSD mint/burn. Share accounting lives on LendingHandler.
 */
abstract contract SovrynHandler is LendingHandler {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sovryn iToken exchange-rate scale (1e18).
     * @return Always `1e18` for this protocol.
     */
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18;

    /// @notice Sovryn iSUSD (or equivalent iToken) this handler mints and burns.
    IiSusdToken public immutable i_iToken;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param stablecoin The stablecoin this handler lends.
     * @param iToken Sovryn iSUSD (or equivalent iToken) for that stablecoin.
     */
    constructor(address dcaManager, address stablecoin, address iToken)
        LendingHandler(dcaManager, stablecoin, EXCHANGE_RATE_DECIMALS)
    {
        i_iToken = IiSusdToken(iToken);
        _approveLendingSpender();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _viewExchangeRate() internal view override returns (uint256) {
        return i_iToken.tokenPrice();
    }

    function _lendingSpender() internal view override returns (address) {
        return address(i_iToken);
    }

    /// @dev Mint only; the base credits the measured iSUSD gain, never `mint()`'s return value.
    function _protocolDeposit(uint256 stablecoinAmount) internal override {
        i_iToken.mint(address(this), stablecoinAmount);
    }

    /**
     * @dev Redeem iSUSD onto this contract. `burn()` can return GROSS while paying NET once an
     *      exit fee is on; the return is ignored and the base measures cash and iToken deltas.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256) internal override {
        i_iToken.burn(address(this), sharesAmount);
    }

    function _receiptSharesBalance() internal override returns (uint256) {
        return i_iToken.balanceOf(address(this));
    }
}
