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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title PurchaseUniswap
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Uniswap V3 purchase route: swap stablecoin for WRBTC, unwrap on withdraw.
 * @dev Min-out is built from the MoC BTC/USD oracle under a $1 peg assumption: one unit of the handler's
 *      stablecoin is taken to be one USD. BitChill only lists 1:1 stables (DOC, USDRIF, USDT0) and does not
 *      run a per-stablecoin USD feed. If a listed stablecoin depegs downwards, the pool prices it below the
 *      oracle-implied floor and the swap reverts; nothing here redeems a depegged stablecoin at $1, and a
 *      persistent depeg is handled by delisting the token, not by the purchase path.
 */
abstract contract PurchaseUniswap is PurchaseRbtc, IPurchaseUniswap {
    using SafeCast for uint256;

    //////////////////////
    // State variables ///
    //////////////////////
    /// @notice Wrapped rBTC token this route swaps into and unwraps on withdraw.
    /// @return The constructor-supplied WRBTC.
    IWRBTC public immutable i_wrBtcToken;
    /// @notice Uniswap V3 SwapRouter02 used to buy WRBTC.
    /// @return The constructor-supplied router.
    ISwapRouter02 public immutable i_swapRouter02;
    ICoinPairPrice internal s_mocOracle;
    uint256 constant HUNDRED_PERCENT = 1 ether;
    /// @notice decimals of the MoC BTC/USD price. Hardcoded because the oracle exposes no `decimals()`.
    uint256 internal constant ORACLE_DECIMALS = 18;
    /// @notice `10 ** (ORACLE_DECIMALS - stablecoin decimals)`, which lifts a stablecoin amount into the oracle's USD units
    /// @dev Fixed at deploy because the handler's stablecoin is immutable. USDT0 is 6 decimals, DOC and USDRIF 18.
    uint256 internal immutable i_stablecoinToUsdScale;
    /// @notice The swap-time slippage fraction, 1e18-scaled like `HUNDRED_PERCENT`. uint128 is ample
    /// for a value that can never exceed 1e18, and pairs it with the safety check in one slot.
    uint128 internal s_amountOutMinimumPercent;
    /// @notice Config-only floor: the lowest `s_amountOutMinimumPercent` the owner may set. Never used at swap time.
    uint128 internal s_amountOutMinimumSafetyCheck;
    bytes internal s_swapPath;
    /// @dev Exact encoded paths this handler may activate. Purchases read `s_swapPath` only.
    mapping(bytes32 pathHash => bool allowed) private s_purchasePathAllowed;

    /**
     * @param uniswapSettings the settings for the uniswap router
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT`, 99.5%)
     * @param amountOutMinimumSafetyCheck The lowest percent the owner may later configure
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK`, 95%)
     * @dev Reads the stablecoin's `decimals()` once and stores the scaling factor min-out needs, so a
     *      6-decimal stablecoin is not read as an 18-decimal one. Tokens with more than 18 decimals are
     *      rejected rather than rounded down to a weaker floor. The quotient is WRBTC wei because
     *      `s_amountOutMinimumPercent` is 1e18-scaled (`HUNDRED_PERCENT`) and WRBTC is 18 decimals — the
     *      same known-token assumption as hardcoding the oracle at `ORACLE_DECIMALS`.
     * @dev Builds the initial path through `_purchaseToken()`. The concrete funding base
     *      (TokenHandler via LendingErc20Handler / IdleErc20Handler) must initialize
     *      `i_stableToken` before this constructor body runs — the leaf `is` order lists
     *      the funding base before `PurchaseUniswap`. `_encodePurchasePath` reverts if that
     *      token is still `address(0)`, so a reversed `is` list fails at deploy rather
     *      than writing a path that cannot be bought or repaired. Constructor installation
     *      encodes once, writes `s_swapPath`, and marks that hash allowed — the initial path
     *      is approved by deployment. Later paths are owner-approved through `setPurchasePathAllowed`.
     */
    constructor(
        UniswapSettings memory uniswapSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck
    ) 
    {
        i_swapRouter02 = uniswapSettings.swapRouter02;
        i_wrBtcToken = uniswapSettings.wrBtcToken;
        s_mocOracle = uniswapSettings.mocOracle;

        _validateSlippageSettings(amountOutMinimumPercent, amountOutMinimumSafetyCheck);

        s_amountOutMinimumPercent = amountOutMinimumPercent.toUint128();
        s_amountOutMinimumSafetyCheck = amountOutMinimumSafetyCheck.toUint128();
        
        // Direct initial owner is not the deployer, so the constructor cannot call the onlyOwner setters.
        // Encode once, write the active path, and mark that hash allowed. A zero purchase token
        // reverts here, before the `decimals()` call below reaches an empty address.
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
                               FUNCTIONS
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
     * @dev Writes `s_swapPath` and emits `PurchaseUniswap_NewPathSet`.
     *      `newPath` must be `_encodePurchasePath(intermediateTokens, poolFeeRates)`;
     *      the event's components are how off-chain reconstructs the route.
     */
    function _setPurchasePath(
        address[] memory intermediateTokens,
        uint24[] memory poolFeeRates,
        bytes memory newPath
    ) internal {
        s_swapPath = newPath;
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
     * @dev Swap net stablecoin for WRBTC and return the handler's WRBTC-balance delta.
     */
    function _purchaseRbtc(uint256 stablecoinAmount) internal override returns (uint256) {
        return _swapStablecoinForWrbtc(stablecoinAmount);
    }

    /**
     * @param stablecoinAmountToSpend the amount of stablecoin to swap for rBTC
     * @return amountOut the amount of WRBTC this contract actually received
     * @dev The router's return value is treated as success/failure only; the measured WRBTC balance delta is
     * the amount we can credit. amountOutMinimum still bounds the swap.
     */
    function _swapStablecoinForWrbtc(uint256 stablecoinAmountToSpend) internal returns (uint256 amountOut) {
        // Approve the router to spend stablecoin.
        TransferHelper.safeApprove(address(_purchaseToken()), address(i_swapRouter02), stablecoinAmountToSpend);

        // Set up the swap parameters
        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: s_swapPath,
            recipient: address(this),
            amountIn: stablecoinAmountToSpend,
            amountOutMinimum: _getAmountOutMinimum(stablecoinAmountToSpend)
        });

        uint256 wrBtcBalanceBefore = i_wrBtcToken.balanceOf(address(this));
        i_swapRouter02.exactInput(params);
        amountOut = i_wrBtcToken.balanceOf(address(this)) - wrBtcBalanceBefore;
    }

    /**
     * @param stablecoinAmountToSpend the amount of stablecoin to swap for rBTC
     * @return minimumRbtcAmount the minimum amount of rBTC that must be received
     * @dev `stablecoinAmountToSpend * i_stablecoinToUsdScale` is the USD notional in the oracle's decimals
     * under the $1 peg assumption. Oracle decimals cancel in the division, leaving BTC as a 0.xxx integer;
     * multiplying by `s_amountOutMinimumPercent` (1e18-scaled) both applies slippage and converts to wei.
     * Those wei are WRBTC's units because WRBTC is 18 decimals.
     * @dev The oracle `isValid` bit is checked at execution, not at signing: a transaction that sits in the
     * mempool is priced by the oracle of the block that mines it. This floor is the only bound on a stale or
     * sandwiched swap. `ExactInputParams` carries no deadline, and the one mechanism SwapRouter02 does offer
     * — `IMulticallExtended.multicall(uint256 deadline, bytes[])` — cannot help here: a deadline this contract
     * derives from `block.timestamp` while executing is satisfied by construction. Only a deadline supplied by
     * the caller bounds anything, and that means a `batchBuyRbtc` argument, not a handler change.
     * @dev This is a revert bound, not an accounting input: what the handler credits is the measured WRBTC
     * balance delta in `_swapStablecoinForWrbtc`.
     */
    function _getAmountOutMinimum(uint256 stablecoinAmountToSpend) internal view returns (uint256 minimumRbtcAmount) {
        (uint256 currentPrice, bool isValid, ) = s_mocOracle.getPriceInfo();
        if (!isValid) revert PurchaseUniswap__OutdatedPrice();
        minimumRbtcAmount = (stablecoinAmountToSpend * i_stablecoinToUsdScale * s_amountOutMinimumPercent) / currentPrice;
    }

}
