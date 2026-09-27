// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LendingHandler} from "../LendingHandler.sol";
import {IkToken} from "./IkToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TropykusErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Tropykus adapter: Compound-style kToken mint/redeem. Share accounting lives on LendingHandler.
 * @dev Test-only adapter, excluded from production deployment; local and fork lanes retain coverage.
 */
abstract contract TropykusErc20Handler is LendingHandler {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tropykus kToken exchange-rate scale (1e18).
     * @return Always `1e18` for this protocol.
     */
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e18;

    /**
     * @notice Tropykus kToken this handler mints and redeems.
     * @return The constructor-supplied kToken.
     */
    IkToken public immutable i_kToken;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stableTokenAddress The ERC20 stablecoin this handler lends.
     * @param kTokenAddress Tropykus kToken for that stablecoin.
     */
    constructor(address dcaManagerAddress, address stableTokenAddress, address kTokenAddress)
        LendingHandler(dcaManagerAddress, stableTokenAddress, EXCHANGE_RATE_DECIMALS)
    {
        i_kToken = IkToken(kTokenAddress);
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

    /// @dev The kToken credited is the balance actually gained, never `mint()`'s return value.
    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        uint256 prevKtokenBalance = i_kToken.balanceOf(address(this));
        if (i_kToken.mint(stablecoinAmount) != 0) revert LendingHandler__LendingProtocolDepositFailed();
        mintedShares = i_kToken.balanceOf(address(this)) - prevKtokenBalance;
    }

    /**
     * @dev Redeem kTokens and pay `receiver`. Burns the booked share count. `redeem` has no
     *      receiver, so cash lands here first and this contract forwards what it gained. Only the
     *      Compound return code is raised here; the base measures cash and kToken deltas.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256, address receiver) internal override {
        bool forward = receiver != address(this);
        uint256 balanceBefore = forward ? i_stableToken.balanceOf(address(this)) : 0;
        uint256 result = i_kToken.redeem(sharesAmount);
        if (result != 0) revert LendingHandler__LendingProtocolRedeemFailed(result);
        if (forward) {
            i_stableToken.safeTransfer(receiver, i_stableToken.balanceOf(address(this)) - balanceBefore);
        }
    }

    function _receiptSharesBalance() internal override returns (uint256) {
        return i_kToken.balanceOf(address(this));
    }
}
