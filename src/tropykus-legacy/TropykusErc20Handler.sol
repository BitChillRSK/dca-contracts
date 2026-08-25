// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IkToken} from "./IkToken.sol";

/**
 * @title TropykusErc20Handler
 * @notice Tropykus adapter: Compound-style kToken mint/redeem. Share accounting lives on LendingErc20Handler.
 */
abstract contract TropykusErc20Handler is LendingErc20Handler {
    /// @notice Compound-style exchange-rate scale. Fixed for this protocol; not a constructor arg
    ///         (LayerBank's RAY is 1e27 — passing that here would size withdrawals 1e9× too small).
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18;

    IkToken public immutable i_kToken;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token on the blockchain of deployment
     * @param kTokenAddress the address of Tropykus'  kToken token contract
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address kTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    )
        LendingErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, EXCHANGE_RATE_DECIMALS)
    {
        i_kToken = IkToken(kTokenAddress);
    }

    function _exchangeRate() internal override returns (uint256) {
        return i_kToken.exchangeRateCurrent();
    }

    function _viewExchangeRate() internal view override returns (uint256) {
        return i_kToken.exchangeRateStored();
    }

    function _lendingSpender() internal view override returns (address) {
        return address(i_kToken);
    }

    /**
     * @notice the kToken we credit is the balance we actually gained, never mint()'s return value
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        uint256 prevKtokenBalance = i_kToken.balanceOf(address(this));
        if (i_kToken.mint(stablecoinAmount) != 0) revert TokenLending__LendingProtocolDepositFailed();
        mintedShares = i_kToken.balanceOf(address(this)) - prevKtokenBalance;
    }

    /**
     * @notice Redeem kTokens onto this contract
     * @dev Burns the booked share count. Only the Compound return code is raised here.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256) internal override {
        uint256 result = i_kToken.redeem(sharesAmount);
        if (result != 0) revert TokenLending__LendingProtocolRedeemFailed(result);
    }
}
