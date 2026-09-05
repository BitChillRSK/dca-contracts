// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseRbtc} from "./PurchaseRbtc.sol";
import {IPurchaseRbtc} from "./interfaces/IPurchaseRbtc.sol";
import {IWRBTC} from "./interfaces/IWRBTC.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {ICoinPairPrice} from "./interfaces/ICoinPairPrice.sol";
import {IPurchaseUniswap} from "./interfaces/IPurchaseUniswap.sol";
import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title PurchaseUniswap
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Uniswap V3 purchase route: swap stablecoin for WRBTC, unwrap on withdraw.
 */
abstract contract PurchaseUniswap is PurchaseRbtc, IPurchaseUniswap {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Wrapped rBTC token this route swaps into and unwraps on withdraw.
    /// @return The constructor-supplied WRBTC.
    IWRBTC public immutable i_wrBtcToken;
    /// @notice Uniswap V3 SwapRouter02 used to buy WRBTC.
    /// @return The constructor-supplied router.
    ISwapRouter02 public immutable i_swapRouter02;
    ICoinPairPrice internal s_mocOracle;
    uint256 internal constant HUNDRED_PERCENT = 1 ether;
    /// @notice decimals of the MoC BTC/USD price. Hardcoded because the oracle exposes no `decimals()`.
    uint256 internal constant ORACLE_DECIMALS = 18;
    /// @notice `10 ** (ORACLE_DECIMALS - stablecoin decimals)`, which lifts a stablecoin amount into the oracle's USD units
    /// @dev Fixed at deploy because the handler's stablecoin is immutable, so a 6-decimal stablecoin
    ///      and an 18-decimal one both reach the oracle's units. Above 18 the constructor reverts.
    uint256 internal immutable i_stablecoinToUsdScale;
    /// @notice The swap-time oracle floor: the fraction of oracle-implied rBTC the router must pay.
    /// @dev Deliberately loose. It is the bound that holds when the caller's `minRbtcOut` is absent,
    /// stale, or hostile, not the operational tightness of a healthy batch — the swapper derives that
    /// from a live quote per batch and can only tighten from here.
    uint128 internal s_amountOutMinimumPercent;
    /// @notice The lowest swap-time floor the owner may configure. Bounds the setter; never used at swap time.
    /// @dev Separate from the live floor because the two answer separate questions: how much slippage is
    /// tolerable in normal operation, and how far the owner may ever widen that. One number for both would
    /// force the live floor down to whatever governance must be able to reach in an emergency. Both are
    /// 1e18-scaled like `HUNDRED_PERCENT`; `uint128` is ample and pairs them in one slot.
    uint128 internal s_amountOutMinimumSafetyCheck;
    bytes internal s_swapPath;
    /// @dev The intermediate tokens encoded inside `s_swapPath`, in hop order. Empty for a direct pair.
    /// Kept as its own array because the purchase must know which tokens a partial fill could strand in the
    /// router, and the setter already has them un-packed. Written only by `_setPurchasePath`, so it cannot
    /// describe a path that is not the active one.
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
     * @dev Reads the stablecoin's `decimals()` once and stores the scaling factor min-out needs, so a
     *      6-decimal stablecoin is not read as an 18-decimal one. Tokens with more than 18 decimals are
     *      rejected rather than rounded down to a weaker floor. The quotient is WRBTC wei because
     *      `s_amountOutMinimumPercent` is 1e18-scaled (`HUNDRED_PERCENT`) and WRBTC is 18 decimals — the
     *      same known-token assumption as hardcoding the oracle at `ORACLE_DECIMALS`. The initial path is
     *      built through `_purchaseToken()`, so the concrete funding base must initialize `i_stableToken`
     *      before this body runs: the leaf `is` order lists the funding base before `PurchaseUniswap`, and
     *      `_encodePurchasePath` reverts on a zero token, so a reversed list fails at deploy rather than
     *      writing a path that can neither be bought nor repaired. Deployment approves that first path;
     *      later ones are owner-approved through `setPurchasePathAllowed`.
     */
    constructor(
        UniswapSettings memory uniswapSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck
    ) {
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

        uint8 stablecoinDecimals = IERC20Metadata(address(_purchaseToken())).decimals();
        if (stablecoinDecimals > ORACLE_DECIMALS) {
            revert PurchaseUniswap__UnsupportedStablecoinDecimals(stablecoinDecimals);
        }
        i_stablecoinToUsdScale = 10 ** (ORACLE_DECIMALS - stablecoinDecimals);
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
     */
    function setPurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates)
        public
        override
    {
        bytes memory newPath = _encodePurchasePath(intermediateTokens, poolFeeRates);
        bytes32 pathHash = keccak256(newPath);
        if (!s_purchasePathAllowed[pathHash]) {
            revert PurchaseUniswap__PurchasePathNotAllowed(pathHash);
        }
        if (msg.sender != owner()) {
            address admin = IDcaManager(i_dcaManager).getOperationsAdminAddress();
            if (!IOperationsAdmin(admin).isSwapper(msg.sender)) {
                revert PurchaseUniswap__UnauthorizedPurchasePathSetter(msg.sender);
            }
        }
        _setPurchasePath(intermediateTokens, poolFeeRates, newPath);
    }

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function setAmountOutMinimumPercent(uint256 amountOutMinimumPercent) external onlyOwner {
        _validateSlippageSettings(amountOutMinimumPercent, s_amountOutMinimumSafetyCheck);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(s_amountOutMinimumPercent, amountOutMinimumPercent);
        s_amountOutMinimumPercent = amountOutMinimumPercent.toUint128();
    }

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function setAmountOutMinimumSafetyCheck(uint256 amountOutMinimumSafetyCheck) external onlyOwner {
        _validateSlippageSettings(s_amountOutMinimumPercent, amountOutMinimumSafetyCheck);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(s_amountOutMinimumSafetyCheck, amountOutMinimumSafetyCheck);
        s_amountOutMinimumSafetyCheck = amountOutMinimumSafetyCheck.toUint128();
    }

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function updateMocOracle(address newOracle) external override onlyOwner {
        if (newOracle == address(0)) {
            revert PurchaseUniswap__InvalidOracleAddress();
        }
        emit PurchaseUniswap_OracleUpdated(address(s_mocOracle), newOracle);
        s_mocOracle = ICoinPairPrice(newOracle);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function getAmountOutMinimumPercent() external view returns (uint256) {
        return s_amountOutMinimumPercent;
    }

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function getAmountOutMinimumSafetyCheck() external view returns (uint256) {
        return s_amountOutMinimumSafetyCheck;
    }

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function getMocOracle() external view returns (ICoinPairPrice) {
        return s_mocOracle;
    }

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function getSwapPath() external view returns (bytes memory) {
        return s_swapPath;
    }

    /**
     * @inheritdoc IPurchaseUniswap
     */
    function isPurchasePathAllowed(bytes32 pathHash) external view returns (bool) {
        return s_purchasePathAllowed[pathHash];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Writes `s_swapPath` and its intermediate tokens together, then emits
     *      `PurchaseUniswap_NewPathSet`. `newPath` must be
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
        emit PurchaseUniswap_NewPathSet(intermediateTokens, poolFeeRates, newPath);
    }

    /**
     * @dev Raw allowlist write and `PurchaseUniswap_PurchasePathAllowedSet`.
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
        emit PurchaseUniswap_PurchasePathAllowedSet(pathHash, encodedPath, intermediateTokens, poolFeeRates, allowed);
    }

    /**
     * @dev Swap net stablecoin for WRBTC and return the handler's WRBTC-balance delta. The router's return
     *      value is treated as success/failure only; the measured delta is the amount we can credit.
     *      `amountOutMinimum` is `max(amountOutLowerBound, minRbtcOut)`, so a caller can tighten the swap
     *      but never loosen it below the configured floor.
     *
     *      `exactInput` states the input the caller asked to spend, not the input the pools took: a V3 pool
     *      stops at its own price limit, so a thin or drained pool can fill part of the request and still
     *      clear an aggregate `amountOutMinimum`. Output-only accounting cannot see that. The unspent
     *      remainder is either stablecoin left on this handler after schedules and fees were already
     *      debited, or, when a later hop stops, an intermediate token stranded in the public router outside
     *      our custody. Both are measured here as balance deltas and either mismatch reverts the whole
     *      purchase, rolling pools, router, fees and schedule effects back together. Router balances are
     *      compared against their own pre-swap values rather than zero, so tokens anyone can send to a
     *      public contract cannot block purchases.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 minRbtcOut)
        internal
        override
        returns (uint256 amountOut)
    {
        IERC20 purchaseToken = _purchaseToken();
        TransferHelper.safeApprove(address(purchaseToken), address(i_swapRouter02), stablecoinAmount);

        uint256 amountOutLowerBound = _getAmountOutLowerBound(stablecoinAmount);
        uint256 amountOutMinimum = minRbtcOut > amountOutLowerBound ? minRbtcOut : amountOutLowerBound;

        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: s_swapPath,
            recipient: address(this),
            amountIn: stablecoinAmount,
            amountOutMinimum: amountOutMinimum
        });

        uint256 inputBalanceBefore = _balanceOf(address(purchaseToken), address(this));

        address[] memory intermediateTokens = s_swapIntermediateTokens;
        uint256 intermediateCount = intermediateTokens.length;
        uint256[] memory routerBalancesBefore = new uint256[](intermediateCount);
        for (uint256 i; i < intermediateCount; ++i) {
            routerBalancesBefore[i] = _balanceOf(intermediateTokens[i], address(i_swapRouter02));
        }

        uint256 wrBtcBalanceBefore = _balanceOf(address(i_wrBtcToken), address(this));
        i_swapRouter02.exactInput(params);

        uint256 inputBalanceAfter = _balanceOf(address(purchaseToken), address(this));
        if (inputBalanceAfter > inputBalanceBefore || inputBalanceBefore - inputBalanceAfter != stablecoinAmount) {
            revert PurchaseUniswap__InputAmountNotFullySpent(stablecoinAmount, inputBalanceBefore, inputBalanceAfter);
        }

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
     * @dev `stablecoinAmountToSpend * i_stablecoinToUsdScale` is the USD notional in the oracle's decimals
     *      under the $1 peg assumption. Oracle decimals cancel in the division, leaving BTC as a 0.xxx
     *      integer; multiplying by `s_amountOutMinimumPercent` (1e18-scaled) both applies slippage and
     *      converts to wei, which are WRBTC's units because WRBTC is 18 decimals. This is a revert bound
     *      and not an accounting input — what the handler credits is the measured WRBTC delta in
     *      `_purchaseRbtc`. The oracle `isValid` bit is read at execution, not at signing, so a transaction
     *      sitting in the mempool is priced by the oracle of the block that mines it, and this floor is
     *      the only bound on a stale or sandwiched swap. There is deliberately no swap deadline to go with
     *      it: SwapRouter02's `ExactInputParams` has no deadline field, and its `multicall(deadline, ...)`
     *      overload only checks the value the caller passes, so a deadline this handler computed from
     *      `block.timestamp` mid-execution would always pass. A binding deadline has to be chosen by the
     *      swapper before signing, so adding one means a new `batchBuyRbtc` argument, not a change here.
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
     *      `intermediateTokens.length + 1`. Reverts if `_purchaseToken()` is still
     *      unset, so a reversed inheritance `is` list fails at deploy.
     */
    function _encodePurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates)
        private
        view
        returns (bytes memory newPath)
    {
        if (poolFeeRates.length != intermediateTokens.length + 1) {
            revert PurchaseUniswap__WrongNumberOfTokensOrFeeRates(intermediateTokens.length, poolFeeRates.length);
        }

        address purchaseToken = address(_purchaseToken());
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
     *      copy of the same encode/staticcall/decode sequence. A purchase makes four of them plus two
     *      per intermediate token, so the saving grows with the path.
     */
    function _balanceOf(address token, address account) private view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }
}
