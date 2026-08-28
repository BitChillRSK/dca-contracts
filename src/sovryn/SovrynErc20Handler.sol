// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IiSusdToken} from "./IiSusdToken.sol";

/**
 * @title SovrynErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn adapter: iSUSD mint/burn. Share accounting lives on LendingErc20Handler.
 */
abstract contract SovrynErc20Handler is LendingErc20Handler {
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18;

    IiSusdToken public immutable i_iSusdToken;

    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stableTokenAddress The stablecoin this handler lends (DOC on the MoC leaf).
     * @param iSusdTokenAddress Sovryn iSUSD (or equivalent iToken) for that stablecoin.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address iSusdTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        LendingErc20Handler(
            dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, EXCHANGE_RATE_DECIMALS, initialOwner
        )
    {
        i_iSusdToken = IiSusdToken(iSusdTokenAddress);
    }

    function _viewExchangeRate() internal view override returns (uint256) {
        return i_iSusdToken.tokenPrice();
    }

    function _lendingSpender() internal view override returns (address) {
        return address(i_iSusdToken);
    }

    /**
     * @dev The iSUSD credited is the balance actually gained, never `mint()`'s return value.
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        uint256 prevIsusdBalance = i_iSusdToken.balanceOf(address(this));
        i_iSusdToken.mint(address(this), stablecoinAmount);
        mintedShares = i_iSusdToken.balanceOf(address(this)) - prevIsusdBalance;
    }

    /**
     * @dev Redeem iSUSD onto this contract. `burn()` can return GROSS while paying NET once an
     *      exit fee is on; the return is ignored and the base measures the token delta.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256) internal override {
        i_iSusdToken.burn(address(this), sharesAmount);
    }
}
