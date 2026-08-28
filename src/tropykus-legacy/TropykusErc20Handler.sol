// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IkToken} from "./IkToken.sol";

/**
 * @title TropykusErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Tropykus adapter: Compound-style kToken mint/redeem. Share accounting lives on LendingErc20Handler.
 * @dev Legacy only: no live deploy path. Local and fork lanes still cover this second lending adapter.
 */
abstract contract TropykusErc20Handler is LendingErc20Handler {
    /// @notice Tropykus kToken exchange-rate scale (1e18).
    /// @return Always `1e18` for this protocol.
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18;

    /// @notice Tropykus kToken this handler mints and redeems.
    /// @return The constructor-supplied kToken.
    IkToken public immutable i_kToken;

    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stableTokenAddress The ERC20 stablecoin this handler lends.
     * @param kTokenAddress Tropykus kToken for that stablecoin.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address kTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        LendingErc20Handler(
            dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, EXCHANGE_RATE_DECIMALS, initialOwner
        )
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
     * @dev The kToken credited is the balance actually gained, never `mint()`'s return value.
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        uint256 prevKtokenBalance = i_kToken.balanceOf(address(this));
        if (i_kToken.mint(stablecoinAmount) != 0) revert TokenLending__LendingProtocolDepositFailed();
        mintedShares = i_kToken.balanceOf(address(this)) - prevKtokenBalance;
    }

    /**
     * @dev Redeem kTokens onto this contract. Burns the booked share count. Only the Compound
     *      return code is raised here; the base measures the token delta.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256) internal override {
        uint256 result = i_kToken.redeem(sharesAmount);
        if (result != 0) revert TokenLending__LendingProtocolRedeemFailed(result);
    }
}
