// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IkToken} from "./IkToken.sol";

/**
 * @title TropykusErc20Handler
 * @notice Tropykus adapter: Compound-style kToken mint/redeem. Share accounting lives on LendingErc20Handler.
 */
abstract contract TropykusErc20Handler is LendingErc20Handler {
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
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        LendingErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, exchangeRateDecimals)
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
     * @notice Compound kToken redemption onto this contract
     * @dev The `stablecoinAmount > 0 &&` conjunct is the Compound analogue of LayerBank skipping a
     *      zero Pool.withdraw: `redeemUnderlying(0)` / `redeem(0)` can succeed and pay 0.
     */
    function _protocolRedeem(uint256 stablecoinAmount, uint256 sharesAmount, bool sizeByUnderlying, uint256)
        internal
        override
        returns (uint256 received)
    {
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));

        uint256 result;
        if (sizeByUnderlying) {
            result = i_kToken.redeemUnderlying(stablecoinAmount);
        } else {
            result = i_kToken.redeem(sharesAmount);
        }

        if (result != 0) revert TokenLending__LendingProtocolRedeemFailed(result);

        received = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        // @notice a success code with no stablecoin received still burnt the user's kToken, so revert
        // instead of paying out zero
        if (stablecoinAmount > 0 && received == 0) {
            revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
        }
    }
}
