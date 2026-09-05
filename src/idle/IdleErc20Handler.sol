// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TokenHandler} from "src/TokenHandler.sol";
import {StablecoinSource} from "src/StablecoinSource.sol";
import {IIdleErc20Handler} from "./IIdleErc20Handler.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IdleErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Base for the handlers that hold their stablecoin instead of lending it; each leaf adds a
 *         purchase route.
 */
abstract contract IdleErc20Handler is TokenHandler, IIdleErc20Handler, StablecoinSource {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(address user => uint256 balance) internal s_idleBalances;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dcaManagerAddress The DcaManager allowed to call deposit and withdraw.
     * @param stableTokenAddress The ERC20 stablecoin this handler holds idle.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    ) TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ITokenHandler
     * @dev TokenHandler owns the balance-delta measurement and reverts unless the delta equals the
     *      request, so a fee-on-transfer token never reaches the idle balance. The idle mapping is
     *      credited with the request.
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override
        onlyDcaManager
    {
        super.depositToken(user, depositAmount);
        s_idleBalances[user] += depositAmount;
    }

    /**
     * @inheritdoc ITokenHandler
     */
    function withdrawToken(address user, uint256 withdrawalAmount)
        public
        override
        onlyDcaManager
        returns (uint256)
    {
        uint256 requested = withdrawalAmount;
        withdrawalAmount = _debitIdleBalance(user, withdrawalAmount);
        if (requested > 0 && withdrawalAmount == 0) revert IdleErc20Handler__ZeroStablecoinPaid(requested);
        return super.withdrawToken(user, withdrawalAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IIdleErc20Handler
     */
    function getUsersIdleTokenBalance(address user) external view override returns (uint256) {
        return s_idleBalances[user];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The stablecoin this handler holds idle.
     */
    function _purchaseToken() internal view override returns (IERC20) {
        return i_stableToken;
    }

    /**
     * @dev Retrieve `amount` of the user's idle stablecoin for the purchase path. A lending handler
     *      redeems shares to pull the stablecoin onto itself first; an idle one already holds it, so
     *      this only debits the mapping.
     */
    function _retrieveStablecoin(address user, uint256 amount) internal virtual override returns (uint256) {
        return _debitIdleBalance(user, amount);
    }

    /**
     * @dev Debit each buyer's idle balance for a batch purchase, in row order. A buyer who cannot cover
     *      a row in full has that row zeroed for the caller rather than clamped or reverted: clamping
     *      would return a short total that `PurchaseRbtc` still splits by the original weights, so one
     *      underfunded buyer would be paid for out of every other buyer's stablecoin, and reverting
     *      would let one buyer's shortfall cost every other row in the tick its purchase.
     *
     *      Idle balances are one-to-one with no exchange rate, so nothing here rounds and the manager's
     *      own balance check already covers a single-schedule buyer. It stays as a filter anyway,
     *      because the idle book is pooled per buyer just like the lending one, and because the two
     *      handler families have to answer the manager the same way.
     */
    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts)
        internal
        virtual
        override
        returns (uint256 totalWithdrawn, uint256[] memory unfundedRows)
    {
        uint256 numOfRows = users.length;
        uint256 numOfUnfundedRows;
        for (uint256 i; i < numOfRows; ++i) {
            uint256 amount = purchaseAmounts[i];
            if (amount == 0) continue;
            uint256 idleBalance = s_idleBalances[users[i]];
            if (amount > idleBalance) {
                purchaseAmounts[i] = 0;
                // Allocated on the first drop only; a batch that funds everything never pays for it.
                if (numOfUnfundedRows == 0) unfundedRows = new uint256[](numOfRows);
                unfundedRows[numOfUnfundedRows++] = i;
                continue;
            }
            s_idleBalances[users[i]] = idleBalance - amount;
            totalWithdrawn += amount;
        }
        if (numOfUnfundedRows != 0) unfundedRows = _trimRowIndexes(unfundedRows, numOfUnfundedRows);
    }

    /**
     * @dev Clamp `amount` to the user's idle balance and debit it.
     */
    function _debitIdleBalance(address user, uint256 amount) internal returns (uint256) {
        uint256 idleBalance = s_idleBalances[user];
        if (idleBalance < amount) {
            emit IdleErc20Handler__AmountAdjusted(user, amount, idleBalance);
            amount = idleBalance;
        }
        s_idleBalances[user] = idleBalance - amount;
        return amount;
    }
}
