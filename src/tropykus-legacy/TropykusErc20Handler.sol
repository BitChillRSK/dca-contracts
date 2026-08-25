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
     * @dev Sized by shares, like Sovryn: `redeem` burns exactly the count the base booked out, so the
     *      book debit can never come out below what Tropykus burns. `redeemUnderlying` is not used —
     *      it would let Tropykus derive the burn from its own rate instead.
     *      The Compound return code is the only failure this adapter raises; a success code that pays
     *      nothing is the base's call, because it is not protocol-specific.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256) internal override {
        uint256 result = i_kToken.redeem(sharesAmount);
        if (result != 0) revert TokenLending__LendingProtocolRedeemFailed(result);
    }
}
