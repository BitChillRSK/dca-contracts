// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IiSusdToken} from "./IiSusdToken.sol";

/**
 * @title SovrynErc20Handler
 * @notice Sovryn adapter: iSUSD mint/burn. Share accounting lives on LendingErc20Handler.
 */
abstract contract SovrynErc20Handler is LendingErc20Handler {
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
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        LendingErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, exchangeRateDecimals)
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
     * @notice redeem the user's iSusd onto this contract
     * @dev Ignores `sizeByUnderlying`. Sovryn's burn() returns the GROSS amount and pays the NET
     *      one once an exit fee is enabled (SIP-0094), so this contract's measured balance delta
     *      is the only trustworthy amount. Interest is forwarded by the base after this returns.
     */
    function _protocolRedeem(uint256 stablecoinAmount, uint256 sharesAmount, bool, uint256)
        internal
        override
        returns (uint256 received)
    {
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        i_iSusdToken.burn(address(this), sharesAmount);
        received = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        if (received == 0) revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
    }
}
