// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseRbtc} from "./PurchaseRbtc.sol";
import {IPurchaseRbtc} from "./interfaces/IPurchaseRbtc.sol";
import {IWRBTC} from "./interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "./interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "./interfaces/ICoinPairPrice.sol";
import {IPurchaseUniswap} from "./interfaces/IPurchaseUniswap.sol";
import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title PurchaseUniswap
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Uniswap V3 purchase route: swap stablecoin for WRBTC, unwrap on withdraw.
 */
abstract contract PurchaseUniswap is PurchaseRbtc, IPurchaseUniswap {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Wrapped rBTC token this route swaps into and unwraps on withdraw.
     * @return The constructor-supplied WRBTC.
     */
    IWRBTC public immutable i_wrBtcToken;
    /**
     * @notice Uniswap V3 SwapRouter02 used to buy WRBTC.
     * @return The constructor-supplied router.
     */
    IUniswapV3SwapRouter public immutable i_swapRouter02;
    ICoinPairPrice internal s_mocOracle;
    uint256 internal constant HUNDRED_PERCENT = 1 ether;
    /// @notice decimals of the MoC BTC/USD price. Hardcoded because the oracle exposes no `decimals()`.
    uint256 internal constant ORACLE_DECIMALS = 18;
    /**
     * @notice `10 ** (ORACLE_DECIMALS - stablecoin decimals)`, which lifts a stablecoin amount into the oracle's USD units
     * @dev Fixed at deploy because the handler's stablecoin is immutable, so a 6-decimal stablecoin
     *      and an 18-decimal one both reach the oracle's units. Above 18 the constructor reverts.
     */
    uint256 internal immutable i_stablecoinToUsdScale;
    /**
     * @notice The swap-time oracle floor: the fraction of oracle-implied rBTC the router must pay.
     * @dev Deliberately loose. It is the bound that holds when the caller's `minRbtcOut` is absent,
     * stale, or hostile, not the operational tightness of a healthy batch — the swapper derives that
     * from a live quote per batch and can only tighten from here.
     */
    uint128 internal s_amountOutMinimumPercent;
    /**
     * @notice The lowest swap-time floor the owner may configure. Bounds the setter; never used at swap time.
     * @dev Separate from the live floor so governance's emergency range need not weaken normal execution.
     *      Both are 1e18-scaled and packed together as `uint128`.
     */
    uint128 internal s_amountOutMinimumSafetyCheck;
    bytes internal s_swapPath;
    /// @dev Active path's intermediate tokens, retained so purchases can detect router-stranded balances.
    address[] internal s_swapIntermediateTokens;
    /// @dev Exact encoded paths this handler may activate. Purchases read `s_swapPath` only.
    mapping(bytes32 pathHash => bool allowed) private s_purchasePathAllowed;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param uniswapSettings the settings for the uniswap router
     * @param amountOutMinimumPercent The swap-time oracle floor
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT`)
     * @param amountOutMinimumSafetyCheck The lowest floor the owner may later configure
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK`, 95%)
     * @dev Caches the stablecoin-to-18-decimal oracle scale; tokens above 18 decimals revert rather than
     *      weakening the floor through rounding. Path construction reads shared `i_stableToken` (order-
     *      independent); a zero value reverts. The initial path is allowlisted here; later paths need
     *      owner approval.
     */
    constructor(
        UniswapSettings memory uniswapSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck
    ) {
        if (address(uniswapSettings.mocOracle) == address(0)) {
            revert PurchaseUniswap__InvalidOracleAddress();
        }
        i_swapRouter02 = uniswapSettings.swapRouter02;
        i_wrBtcToken = uniswapSettings.wrBtcToken;
        s_mocOracle = uniswapSettings.mocOracle;

        _validateSlippageSettings(amountOutMinimumPercent, amountOutMinimumSafetyCheck);

        s_amountOutMinimumPercent = amountOutMinimumPercent.toUint128();
        s_amountOutMinimumSafetyCheck = amountOutMinimumSafetyCheck.toUint128();

        // The initial owner is not the deployer, so the constructor cannot call the onlyOwner setters
        // and must install the first path itself. This must stay above the `decimals()` read below:
        // encoding reverts on a zero purchase token, before that read reaches an empty address.
        address[] memory intermediateTokens = uniswapSettings.swapIntermediateTokens;
        uint24[] memory poolFeeRates = uniswapSettings.swapPoolFeeRates;
        bytes memory newPath = _encodePurchasePath(intermediateTokens, poolFeeRates);
        bytes32 pathHash = keccak256(newPath);
        _setPurchasePath(intermediateTokens, poolFeeRates, newPath);
        _setPurchasePathAllowed(pathHash, newPath, intermediateTokens, poolFeeRates, true);

        uint8 stablecoinDecimals = IERC20Metadata(address(i_stableToken)).decimals();
        if (stablecoinDecimals > ORACLE_DECIMALS) {
            revert PurchaseUniswap__UnsupportedStablecoinDecimals(stablecoinDecimals);
        }
        i_stablecoinToUsdScale = 10 ** (ORACLE_DECIMALS - stablecoinDecimals);

        _approveSwapRouter();
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @inheritdoc IPurchaseRbtc
     * @dev Unwraps WRBTC to native rBTC before paying the signer.
     */
    function withdrawAccumulatedRbtc(address user) external override onlyDcaManager {
        uint256 rbtcBalance = _withdrawRbtcChecksEffects(user);

        // Unwrap rBTC
        i_wrBtcToken.withdraw(rbtcBalance);

        // Transfer RBTC from this contract back to the user
        _withdrawRbtc(user, rbtcBalance);
    }

    /**
     * @inheritdoc IPurchaseUniswap
     * @dev The arrays are `memory` on purpose. The path helpers they reach are shared with the
     *      constructor, which can only pass `memory`, so `calldata` here would be copied at each helper
     *      call. That measured dearer than the single copy the ABI decoder makes.
     */
    function setPurchasePathAllowed(
        address[] memory intermediateTokens,
        uint24[] memory poolFeeRates,
        bool allowed
    ) external onlyOwner {
        bytes memory encodedPath = _encodePurchasePath(intermediateTokens, poolFeeRates);
        bytes32 pathHash = keccak256(encodedPath);
        if (!allowed && keccak256(s_swapPath) == pathHash) {
            revert PurchaseUniswap__CannotRevokeActivePurchasePath(pathHash);
        }
        if (s_purchasePathAllowed[pathHash] == allowed) {
            revert PurchaseUniswap__PurchasePathPermissionUnchanged(pathHash, allowed);
        }
        _setPurchasePathAllowed(pathHash, encodedPath, intermediateTokens, poolFeeRates, allowed);
    }

    /**
     * @inheritdoc IPurchaseUniswap
     * @dev The arrays are `memory` on purpose. The path helpers they reach are shared with the
     *      constructor, which can only pass `memory`, so `calldata` here would be copied at each helper
     *      call. That measured dearer than the single copy the ABI decoder makes.
     */
    function setPurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates)
        external
        override
    {
        bytes memory newPath = _encodePurchasePath(intermediateTokens, poolFeeRates);
        bytes32 pathHash = keccak256(newPath);
        if (!s_purchasePathAllowed[pathHash]) {
            revert PurchaseUniswap__PurchasePathNotAllowed(pathHash);
        }
        if (msg.sender != owner()) {
            if (!IDcaManager(i_dcaManager).i_operationsAdmin().isSwapper(msg.sender)) {
                revert PurchaseUniswap__UnauthorizedPurchasePathSetter(msg.sender);
            }
        }
        _setPurchasePath(intermediateTokens, poolFeeRates, newPath);
    }

    /// @inheritdoc IPurchaseUniswap
    function setAmountOutMinimumPercent(uint256 amountOutMinimumPercent) external onlyOwner {
        _validateSlippageSettings(amountOutMinimumPercent, s_amountOutMinimumSafetyCheck);
        emit PurchaseUniswap__AmountOutMinimumPercentUpdated(s_amountOutMinimumPercent, amountOutMinimumPercent);
        s_amountOutMinimumPercent = amountOutMinimumPercent.toUint128();
    }

    /// @inheritdoc IPurchaseUniswap
    function setAmountOutMinimumSafetyCheck(uint256 amountOutMinimumSafetyCheck) external onlyOwner {
        _validateSlippageSettings(s_amountOutMinimumPercent, amountOutMinimumSafetyCheck);
        emit PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated(s_amountOutMinimumSafetyCheck, amountOutMinimumSafetyCheck);
        s_amountOutMinimumSafetyCheck = amountOutMinimumSafetyCheck.toUint128();
    }

    /// @inheritdoc IPurchaseUniswap
    function updateMocOracle(address newOracle) external override onlyOwner {
        if (newOracle == address(0)) {
            revert PurchaseUniswap__InvalidOracleAddress();
        }
        emit PurchaseUniswap__OracleUpdated(address(s_mocOracle), newOracle);
        s_mocOracle = ICoinPairPrice(newOracle);
    }

    /// @inheritdoc IPurchaseUniswap
    function restoreSwapRouterApproval() external override {
        _approveSwapRouter();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPurchaseUniswap
    function getAmountOutMinimumPercent() external view returns (uint256) {
        return s_amountOutMinimumPercent;
    }

    /// @inheritdoc IPurchaseUniswap
    function getAmountOutMinimumSafetyCheck() external view returns (uint256) {
        return s_amountOutMinimumSafetyCheck;
    }

    /// @inheritdoc IPurchaseUniswap
    function getMocOracle() external view returns (ICoinPairPrice) {
        return s_mocOracle;
    }

    /// @inheritdoc IPurchaseUniswap
    function getSwapPath() external view returns (bytes memory) {
        return s_swapPath;
    }

    /// @inheritdoc IPurchaseUniswap
    function isPurchasePathAllowed(bytes32 pathHash) external view returns (bool) {
        return s_purchasePathAllowed[pathHash];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Writes `s_swapPath` and its intermediate tokens together, then emits
     *      `PurchaseUniswap__NewPathSet`. `newPath` must be
     *      `_encodePurchasePath(intermediateTokens, poolFeeRates)`; the event's components are how
     *      off-chain reconstructs the route. The two writes are one statement pair on purpose: the
     *      purchase checks the router against the active path's intermediate tokens, and a path
     *      activation that left the previous set behind would check the wrong tokens.
     */
    function _setPurchasePath(
        address[] memory intermediateTokens,
        uint24[] memory poolFeeRates,
        bytes memory newPath
    ) internal {
        s_swapPath = newPath;
        s_swapIntermediateTokens = intermediateTokens;
        emit PurchaseUniswap__NewPathSet(intermediateTokens, poolFeeRates, newPath);
    }

    /**
     * @dev Raw allowlist write and `PurchaseUniswap__PurchasePathAllowedSet`.
     *      The caller must already have rejected a no-op permission write and, when
     *      `allowed` is false, revocation of `keccak256(s_swapPath)`, so every emit is a
     *      real transition and the active path stays allowed. `encodedPath` must be
     *      `_encodePurchasePath(intermediateTokens, poolFeeRates)` and `pathHash` must be
     *      `keccak256(encodedPath)`.
     */
    function _setPurchasePathAllowed(
        bytes32 pathHash,
        bytes memory encodedPath,
        address[] memory intermediateTokens,
        uint24[] memory poolFeeRates,
        bool allowed
    ) internal {
        s_purchasePathAllowed[pathHash] = allowed;
        emit PurchaseUniswap__PurchasePathAllowedSet(pathHash, encodedPath, intermediateTokens, poolFeeRates, allowed);
    }

    function _approveSwapRouter() internal {
        i_stableToken.forceApprove(address(i_swapRouter02), type(uint256).max);
    }

    /**
     * @dev Uses the stricter of the oracle and caller floors, and credits only the measured WRBTC delta.
     *      PurchaseRbtc proves the exact stablecoin input left this handler. This venue-specific layer also
     *      requires every intermediate-token router balance to return to its pre-swap value. Comparing
     *      deltas, not zero balances, prevents donated tokens from blocking it.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 minRbtcOut)
        internal
        override
        returns (uint256 amountOut)
    {
        uint256 amountOutLowerBound = _getAmountOutLowerBound(stablecoinAmount);
        uint256 amountOutMinimum = minRbtcOut > amountOutLowerBound ? minRbtcOut : amountOutLowerBound;

        IUniswapV3SwapRouter.ExactInputParams memory params = IUniswapV3SwapRouter.ExactInputParams({
            path: s_swapPath,
            recipient: address(this),
            amountIn: stablecoinAmount,
            amountOutMinimum: amountOutMinimum
        });

        address[] memory intermediateTokens = s_swapIntermediateTokens;
        uint256 intermediateCount = intermediateTokens.length;
        uint256[] memory routerBalancesBefore = new uint256[](intermediateCount);
        for (uint256 i; i < intermediateCount; ++i) {
            routerBalancesBefore[i] = _balanceOf(intermediateTokens[i], address(i_swapRouter02));
        }

        uint256 wrBtcBalanceBefore = _balanceOf(address(i_wrBtcToken), address(this));
        i_swapRouter02.exactInput(params);

        for (uint256 i; i < intermediateCount; ++i) {
            uint256 routerBalanceAfter = _balanceOf(intermediateTokens[i], address(i_swapRouter02));
            if (routerBalanceAfter != routerBalancesBefore[i]) {
                revert PurchaseUniswap__IntermediateBalanceChangedInRouter(
                    intermediateTokens[i], routerBalancesBefore[i], routerBalanceAfter
                );
            }
        }

        amountOut = _balanceOf(address(i_wrBtcToken), address(this)) - wrBtcBalanceBefore;
    }

    /**
     * @param stablecoinAmountToSpend the amount of stablecoin to swap for rBTC
     * @return minimumRbtcAmount the minimum amount of rBTC that must be received
     * @dev Assumes the stablecoin is USD-pegged and scales its amount to the 18-decimal BTC/USD oracle;
     *      the 1e18 floor factor leaves the result in WRBTC wei. The oracle validity and price are checked
     *      in the execution block; accounting still uses the measured WRBTC delta. SwapRouter02 exact-input
     *      params have no deadline, and a deadline derived here from `block.timestamp` would be tautological;
     *      a binding deadline would have to come from the swapper as a new batch argument.
     */
    function _getAmountOutLowerBound(uint256 stablecoinAmountToSpend) internal view returns (uint256 minimumRbtcAmount) {
        (uint256 currentPrice, bool isValid,) = s_mocOracle.getPriceInfo();
        if (!isValid) revert PurchaseUniswap__OutdatedPrice();
        minimumRbtcAmount =
            (stablecoinAmountToSpend * i_stablecoinToUsdScale * s_amountOutMinimumPercent) / currentPrice;
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Uniswap V3 `exactInput` bytes: this handler's stablecoin, then each
     *      `(fee, intermediateToken)`, then the last fee and WRBTC. Empty
     *      `intermediateTokens` is a direct pair. `poolFeeRates.length` must be
     *      `intermediateTokens.length + 1`. Reverts if `i_stableToken` is zero.
     */
    function _encodePurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates)
        private
        view
        returns (bytes memory newPath)
    {
        if (poolFeeRates.length != intermediateTokens.length + 1) {
            revert PurchaseUniswap__WrongNumberOfTokensOrFeeRates(intermediateTokens.length, poolFeeRates.length);
        }

        address purchaseToken = address(i_stableToken);
        if (purchaseToken == address(0)) revert PurchaseUniswap__ZeroPurchaseToken();

        newPath = abi.encodePacked(purchaseToken);
        for (uint256 i = 0; i < intermediateTokens.length; ++i) {
            newPath = abi.encodePacked(newPath, poolFeeRates[i], intermediateTokens[i]);
        }

        newPath = abi.encodePacked(newPath, poolFeeRates[poolFeeRates.length - 1], address(i_wrBtcToken));
    }

    /**
     * @dev Both arguments are 1e18-scaled fractions. Neither may exceed 100%, and the swap-time floor
     *      cannot sit below the safety check. Keeping that wall means no single owner transaction can
     *      widen the live floor past what governance pre-approved as the worst acceptable fill.
     *      Used by the constructor and both owner setters.
     */
    function _validateSlippageSettings(uint256 amountOutMinimumPercent, uint256 amountOutMinimumSafetyCheck)
        private
        pure
    {
        if (amountOutMinimumPercent > HUNDRED_PERCENT) {
            revert PurchaseUniswap__AmountOutMinimumPercentTooHigh();
        }
        if (amountOutMinimumSafetyCheck > HUNDRED_PERCENT) {
            revert PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh();
        }
        if (amountOutMinimumPercent < amountOutMinimumSafetyCheck) {
            revert PurchaseUniswap__AmountOutMinimumPercentTooLow();
        }
    }

    /**
     * @dev One shared `balanceOf` call site, so the purchase's balance reads do not each emit their own
     *      copy of the same encode/staticcall/decode sequence. A purchase makes two of them plus two
     *      per intermediate token, so the saving grows with the path.
     */
    function _balanceOf(address token, address account) private view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }
}
