// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LendingHandler} from "../LendingHandler.sol";
import {ILayerBankAToken} from "./ILayerBankAToken.sol";
import {ILayerBankHandler} from "./ILayerBankHandler.sol";
import {ILayerBankPool} from "./ILayerBankPool.sol";

/**
 * @title LayerBankHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice LayerBank adapter: Aave-v3 Pool supply/withdraw. Share accounting lives on LendingHandler.
 * @dev Supply and withdraw go through the Pool. Shares are aToken scaled amounts; rebasing
 *      `balanceOf` is never mixed into their accounting.
 */
abstract contract LayerBankHandler is LendingHandler, ILayerBankHandler {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Aave's liquidity-index scale (RAY). Fixed for this protocol; not a constructor
     *         arg (passing Tropykus/Sovryn's 1e18 would size withdrawals 1e9× too large).
     * @return Always `1e27` for this protocol.
     */
    uint256 public constant EXCHANGE_RATE_DECIMALS = 1e27;

    /// @notice LayerBank aToken for this handler's stablecoin.
    ILayerBankAToken public immutable i_aToken;
    /**
     * @notice LayerBank Pool this handler supplies to and withdraws from.
     * @return The pool read from `aToken.POOL()` at construction.
     */
    ILayerBankPool public immutable i_pool;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param stablecoin The ERC20 stablecoin this handler lends.
     * @param aToken LayerBank aToken for that stablecoin.
     */
    constructor(address dcaManager, address stablecoin, address aToken)
        LendingHandler(dcaManager, stablecoin, EXCHANGE_RATE_DECIMALS)
    {
        i_aToken = ILayerBankAToken(aToken);
        if (i_aToken.UNDERLYING_ASSET_ADDRESS() != stablecoin) {
            revert LendingHandler__UnderlyingMismatch();
        }
        address pool = i_aToken.POOL();
        if (pool == address(0)) revert LayerBankHandler__PoolNotSet();
        i_pool = ILayerBankPool(pool);
        _approveLendingSpender();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Aave liquidity index including pending interest, RAY (1e27) scale.
    function _viewExchangeRate() internal view override returns (uint256) {
        return i_pool.getReserveNormalizedIncome(address(i_stablecoin));
    }

    function _lendingSpender() internal view override returns (address) {
        return address(i_pool);
    }

    /// @dev Supply only; the base credits the measured `scaledBalanceOf` gain, never a Pool return.
    function _protocolDeposit(uint256 stablecoinAmount) internal override {
        i_pool.supply(address(i_stablecoin), stablecoinAmount, address(this), 0);
    }

    /**
     * @dev Withdraw the underlying amount whose Aave half-up `rayDiv` maps back to exactly
     *      `sharesAmount` scaled shares. The Pool has no share-sized withdraw; BitChill sizes
     *      shares with a ceiling while Aave burns with nearest-RAY division, so the floored
     *      conversion can undershoot by one wei of underlying. Try floor, then floor + 1, and
     *      leave the shared base to prove the measured `scaledBalanceOf` delta. Assumes
     *      `exchangeRate >= RAY`: Aave's liquidity index starts at `1e27` and only grows (the
     *      live probe asserts that). Below RAY, floor-then-+1 is not always exact — any miss
     *      still reverts in the shared share-consumption check rather than orphaning a claim.
     *      Also assumes the Pool burns half-up. A Pool that rounds the burn up instead burns
     *      exactly `sharesAmount` for the floor and one share more for floor + 1, so every redeem
     *      this sizing bumps would revert in that same check. Below an index of `2 * RAY` no
     *      single amount is exact under both rules, so this is a deployment assumption the live
     *      probe pins, not something the sizing can absorb.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256 exchangeRate) internal override {
        uint256 amountOut = _underlyingForExactScaledBurn(sharesAmount, exchangeRate);
        i_pool.withdraw(address(i_stablecoin), amountOut, address(this));
    }

    function _receiptSharesBalance() internal override returns (uint256) {
        return i_aToken.scaledBalanceOf(address(this));
    }

    /**
     * @dev Underlying `a` such that Aave's `(a * RAY + index/2) / index` equals `sharesAmount`.
     *      Under the `index >= RAY` assumption on `_protocolRedeem`, floor never rayDivs above
     *      the target; when it undershoots, one more wei is enough. Callers only pass
     *      `sharesAmount >= 1` (a single redeem no-ops a zero debit, and every batch row debits at
     *      least one share), so the result is never zero.
     */
    function _underlyingForExactScaledBurn(uint256 sharesAmount, uint256 index) private view returns (uint256 amount) {
        amount = _sharesToStablecoin(sharesAmount, index);
        if (_rayDiv(amount, index) < sharesAmount) {
            unchecked {
                ++amount;
            }
        }
    }

    /// @dev Aave WadRayMath.rayDiv (round nearest).
    function _rayDiv(uint256 a, uint256 index) private pure returns (uint256) {
        return (a * EXCHANGE_RATE_DECIMALS + index / 2) / index;
    }
}
