// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IiSusdToken} from "./IiSusdToken.sol";

/**
 * @title SovrynErc20Handler
 * @notice Sovryn adapter: iSUSD mint/burn. Share accounting lives on LendingErc20Handler.
 */
abstract contract SovrynErc20Handler is LendingErc20Handler {
    /// @notice Sovryn iToken price scale. Fixed for this protocol; not a constructor arg
    ///         (LayerBank's RAY is 1e27 — passing that here would size withdrawals 1e9× too small).
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18;

    IiSusdToken public immutable i_iSusdToken;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param iSusdTokenAddress the address of Sovryn' iSusd token contract
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address iSusdTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    )
        LendingErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, EXCHANGE_RATE_DECIMALS)
    {
        i_iSusdToken = IiSusdToken(iSusdTokenAddress);
    }

    function _exchangeRate() internal view override returns (uint256) {
        return i_iSusdToken.tokenPrice();
    }

    function _viewExchangeRate() internal view override returns (uint256) {
        return i_iSusdToken.tokenPrice();
    }

    function _lendingSpender() internal view override returns (address) {
        return address(i_iSusdToken);
    }

    /**
     * @notice the iSusd we credit is the balance we actually gained, never mint()'s return value
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        uint256 prevIsusdBalance = i_iSusdToken.balanceOf(address(this));
        i_iSusdToken.mint(address(this), stablecoinAmount);
        mintedShares = i_iSusdToken.balanceOf(address(this)) - prevIsusdBalance;
    }

    /**
     * @notice Redeem iSUSD onto this contract
     * @dev burn() can return GROSS while paying NET once an exit fee is on; the return is ignored.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256) internal override {
        i_iSusdToken.burn(address(this), sharesAmount);
    }
}
