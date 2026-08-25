// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {ILayerBankAToken} from "./ILayerBankAToken.sol";
import {ILayerBankErc20Handler} from "./ILayerBankErc20Handler.sol";
import {ILayerBankPool} from "./ILayerBankPool.sol";

/**
 * @title LayerBankErc20Handler
 * @notice LayerBank adapter: Aave-v3 Pool supply/withdraw. Share accounting lives on LendingErc20Handler.
 * @dev Live LayerBank DOC is an Aave-v3 aToken. Supply and withdraw go through the Pool.
 *      Shares in this contract are aToken **scaled** amounts; the rebasing `balanceOf` is never
 *      read, because mixing the two breaks the round-up solvency invariant.
 */
abstract contract LayerBankErc20Handler is LendingErc20Handler, ILayerBankErc20Handler {
    /// @notice Aave liquidity-index scale. Fixed for this protocol; not a constructor arg
    ///         (passing Tropykus/Sovryn's 1e18 would size withdrawals 1e9× too large).
    uint256 public constant RAY = 1e27;

    ILayerBankAToken public immutable i_aToken;
    ILayerBankPool public immutable i_pool;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token on the blockchain of deployment
     * @param aTokenAddress the address of LayerBank's aToken for this stablecoin
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address aTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    ) LendingErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, RAY) {
        i_aToken = ILayerBankAToken(aTokenAddress);
        if (i_aToken.UNDERLYING_ASSET_ADDRESS() != stableTokenAddress) {
            revert LayerBankErc20Handler__UnderlyingMismatch();
        }
        address pool = i_aToken.POOL();
        if (pool == address(0)) revert LayerBankErc20Handler__PoolNotSet();
        i_pool = ILayerBankPool(pool);
    }

    function _exchangeRate() internal view override returns (uint256) {
        return _normalizedIncome();
    }

    function _viewExchangeRate() internal view override returns (uint256) {
        return _normalizedIncome();
    }

    function _lendingSpender() internal view override returns (address) {
        return address(i_pool);
    }

    /**
     * @notice Aave liquidity index including pending interest, RAY (1e27) scale.
     */
    function _normalizedIncome() internal view returns (uint256) {
        return i_pool.getReserveNormalizedIncome(address(i_stableToken));
    }

    /**
     * @notice the shares we credit are the aTokens we actually gained, never a Pool return
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        uint256 prevShares = i_aToken.scaledBalanceOf(address(this));
        i_pool.supply(address(i_stableToken), stablecoinAmount, address(this), 0);
        mintedShares = i_aToken.scaledBalanceOf(address(this)) - prevShares;
    }

    /**
     * @notice withdraw onto this contract and measure
     * @dev Aave has no share-sized withdraw, so the count the base booked out is converted back to
     *      underlying for `Pool.withdraw`. Deriving the amount from that count (rather than passing the
     *      caller's request straight through) is what keeps Aave's own `rayDiv` burn at or below it:
     *      flooring on the way out means the round trip can only shrink. LayerBank is the one adapter
     *      that cannot be share-exact. Live Aave `withdraw` reverts on a zero amount (`InvalidAmount`).
     *      Interest is forwarded by the base after this returns.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256 exchangeRate) internal override {
        uint256 amountOut = _sharesToStablecoin(sharesAmount, exchangeRate);
        // @notice skipping the call is protocol-specific, so it stays here: live Aave `withdraw`
        // reverts on a zero amount (`InvalidAmount`). The base then measures a zero delta and
        // reverts `TokenLending__ZeroStablecoinReceived` when any shares were actually burnt.
        if (amountOut == 0) return;

        i_pool.withdraw(address(i_stableToken), amountOut, address(this));
    }
}
