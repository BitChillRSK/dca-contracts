// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title DcaManager
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Stores every DCA schedule and routes user and swapper calls to the handler that holds the
 *         funds they name.
 * @dev Every external schedule mutator is non-reentrant except the allowlisted-swapper purchase paths,
 *      which complete schedule effects before calling BitChill-deployed handlers. A swapper can open a
 *      self-expiring five-block window that blocks only user mutations capable of invalidating a batch
 *      refreshed after activation. Governance can pause new deposits per route, not purchases or exits.
 */
contract DcaManager is IDcaManager, BitChillOwnable, ReentrancyGuardTransient {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Five block heights including the activation block; fixed because this is an execution
     *      buffer, not a confirmation or finality period.
     */
    uint256 public constant PROTECTED_PURCHASE_WINDOW_BLOCKS = 5;

    /**
     * @dev Constructor-pinned registry. There is no setter: swapping this address
     *      would redirect every live schedule and bypass add-only route assignment.
     */
    IOperationsAdmin public immutable override i_operationsAdmin;

    /**
     * @notice Schedules keyed by their stablecoin and protocol-wide creation id.
     * @dev Keeping both outside the value makes it two slots. A batch row named under the wrong token
     *      addresses nothing; `_callersSchedule` is the single user-ownership check.
     */
    mapping(address token => mapping(uint64 scheduleId => DcaSchedule dcaSchedule)) private s_dcaSchedules;

    /**
     * @notice The ids each user holds for each stablecoin.
     * @dev Enumeration only: purchases never read it.
     */
    mapping(address user => mapping(address token => uint64[] scheduleIds)) private s_scheduleIds;

    ProtocolSettings private s_protocolSettings;
    mapping(address token => uint256) private s_tokenMinPurchaseAmounts; // Per-token minimum purchase amounts
    /**
     * @dev Zero means never activated: every real block number is at least zero, so mutations start
     *      unlocked. While live this holds the first block at which the seven guarded calls resume.
     */
    uint256 private s_userMutationsAllowedFromBlock;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /// @dev The minimum is at least one whole UTC day to preserve the midnight cadence grid.
    modifier validateMinPurchasePeriod(uint256 minPurchasePeriod) {
        if (minPurchasePeriod < 1 days) revert DcaManager__MinPurchasePeriodMustBeAtLeastOneDay();
        if (minPurchasePeriod % 1 days != 0) revert DcaManager__PurchasePeriodMustBeWholeDays();
        _;
    }

    /// @dev Only addresses on the OperationsAdmin swapper allowlist.
    modifier onlySwapper() {
        if (!i_operationsAdmin.isSwapper(msg.sender)) {
            revert DcaManager__UnauthorizedSwapper(msg.sender);
        }
        _;
    }

    /// @dev Refuse only the user actions that can invalidate a batch refreshed after window activation.
    modifier whenUserMutationsAllowed() {
        _requireUserMutationsAllowed();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param operationsAdminAddress The OperationsAdmin this manager is permanently pinned to.
     * @param minPurchasePeriod Minimum time between purchases, in seconds; at least one whole UTC day.
     * @param maxSchedulesPerToken Maximum number of schedules a user may hold per token.
     * @param initialOwner Address that owns this contract immediately after deploy.
     */
    constructor(
        address operationsAdminAddress,
        uint256 minPurchasePeriod,
        uint256 maxSchedulesPerToken,
        address initialOwner
    ) BitChillOwnable(initialOwner) validateMinPurchasePeriod(minPurchasePeriod) {
        if (operationsAdminAddress.code.length == 0) {
            revert DcaManager__OperationsAdminIsNotAContract(operationsAdminAddress);
        }
        i_operationsAdmin = IOperationsAdmin(operationsAdminAddress);
        s_protocolSettings = ProtocolSettings({
            minPurchasePeriod: minPurchasePeriod.toUint32(),
            maxSchedulesPerToken: maxSchedulesPerToken.toUint16(),
            scheduleNonce: 0
        });
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // User operations: schedule lifecycle, funding, withdrawals, and rBTC claims.

    /**
     * @inheritdoc IDcaManager
     * @dev Widths and the bumped nonce are checked before the deposit is pulled, so an overflowing
     *      argument or an exhausted counter reverts with SafeCast data before any token moves.
     */
    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) external override nonReentrant {
        if (token == address(0)) revert DcaManager__TokenNotAccepted(token, routeIndex);
        uint128 deposit = depositAmount.toUint128();
        uint96 purchase = purchaseAmount.toUint96();
        uint32 period = purchasePeriod.toUint32();
        uint32 route = routeIndex.toUint32();

        // One load of the packed scalars, and the id this schedule will carry.
        ProtocolSettings memory settings = s_protocolSettings;
        uint64 scheduleId = (uint256(settings.scheduleNonce) + 1).toUint64();

        _validatePurchasePeriod(purchasePeriod);
        _validateDeposit(depositAmount);
        _handlerForDeposit(token, route).depositToken(msg.sender, depositAmount);
        // The remaining two checks sit after the pull: the minimum purchase amount, validated against
        // the credited request that the handler guarantees equals the amount asked for, and the
        // max-schedules bound below. Both revert the whole call, so a failure returns the deposit.
        _validatePurchaseAmount(token, purchaseAmount, depositAmount);

        uint64[] storage scheduleIds = s_scheduleIds[msg.sender][token];
        if (scheduleIds.length >= settings.maxSchedulesPerToken) {
            revert DcaManager__MaxSchedulesPerTokenReached(token);
        }

        s_protocolSettings.scheduleNonce = scheduleId;

        // A new id addresses empty storage, so the zero cadence anchor and paused flag are left unset.
        _storeNewSchedule(s_dcaSchedules[token][scheduleId], deposit, period, route, msg.sender, purchase);
        scheduleIds.push(scheduleId);
        emit DcaManager__DcaScheduleCreated(
            msg.sender,
            token,
            scheduleId,
            depositAmount,
            purchaseAmount,
            purchasePeriod,
            routeIndex
        );
    }

    /**
     * @inheritdoc IDcaManager
     * @dev Widths are checked before the handler pull so an overflowing credit cannot move tokens.
     */
    function depositToken(address token, uint64 scheduleId, uint256 depositAmount) external override nonReentrant {
        _validateDeposit(depositAmount);
        DcaSchedule storage dcaSchedule = _callersSchedule(token, scheduleId);
        uint128 newTokenBalance = (uint256(dcaSchedule.tokenBalance) + depositAmount.toUint128()).toUint128();
        _handlerForDeposit(token, dcaSchedule.routeIndex).depositToken(msg.sender, depositAmount);
        dcaSchedule.tokenBalance = newTokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /// @inheritdoc IDcaManager
    function updatePurchaseAmount(address token, uint64 scheduleId, uint256 newPurchaseAmount)
        external
        override
        whenUserMutationsAllowed
        nonReentrant
    {
        DcaSchedule storage dcaSchedule = _callersSchedule(token, scheduleId);
        uint96 newAmount = newPurchaseAmount.toUint96();
        _validatePurchaseAmount(token, newAmount, dcaSchedule.tokenBalance);
        uint256 previousPurchaseAmount = dcaSchedule.purchaseAmount;
        dcaSchedule.purchaseAmount = newAmount;
        emit DcaManager__PurchaseAmountUpdated(msg.sender, scheduleId, previousPurchaseAmount, newPurchaseAmount);
    }

    /// @inheritdoc IDcaManager
    function updatePurchasePeriod(address token, uint64 scheduleId, uint256 newPurchasePeriod)
        external
        override
        whenUserMutationsAllowed
        nonReentrant
    {
        DcaSchedule storage dcaSchedule = _callersSchedule(token, scheduleId);
        _validatePurchasePeriod(newPurchasePeriod);
        uint256 previousPurchasePeriod = dcaSchedule.purchasePeriod;
        dcaSchedule.purchasePeriod = newPurchasePeriod.toUint32();
        emit DcaManager__PurchasePeriodUpdated(msg.sender, scheduleId, previousPurchasePeriod, newPurchasePeriod);
    }

    /// @inheritdoc IDcaManager
    function setSchedulePaused(address token, uint64 scheduleId, bool paused)
        external
        override
        whenUserMutationsAllowed
        nonReentrant
    {
        DcaSchedule storage dcaSchedule = _callersSchedule(token, scheduleId);
        if (dcaSchedule.paused == paused) return;
        dcaSchedule.paused = paused;
        emit DcaManager__SchedulePauseSet(msg.sender, scheduleId, paused);
    }

    /// @inheritdoc IDcaManager
    function deleteDcaSchedule(address token, uint64 scheduleId, uint256 scheduleIdIndex)
        external
        override
        whenUserMutationsAllowed
        nonReentrant
    {
        DcaSchedule storage dcaSchedule = _callersSchedule(token, scheduleId);

        // Both fields are read before the schedule is deleted, and both live in its first slot.
        uint256 tokenBalance = dcaSchedule.tokenBalance;
        uint256 routeIndex = dcaSchedule.routeIndex;

        // Both structures drop the schedule before the handler call: the schedule itself, and the id's
        // place in its owner's list for this token.
        _removeScheduleId(msg.sender, token, scheduleId, scheduleIdIndex);
        delete s_dcaSchedules[token][scheduleId];

        uint256 amountWithdrawn;
        if (tokenBalance > 0) {
            amountWithdrawn = _handler(token, routeIndex).withdrawToken(msg.sender, tokenBalance);
        }

        // The event reports what left the handler, which may be less than the schedule's tokenBalance.
        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, amountWithdrawn);
    }

    /// @inheritdoc IDcaManager
    function withdrawToken(address token, uint64 scheduleId, uint256 withdrawalAmount)
        external
        override
        whenUserMutationsAllowed
        nonReentrant
    {
        _withdrawToken(token, scheduleId, withdrawalAmount);
    }

    /**
     * @inheritdoc IDcaManager
     * @dev The route index is captured from the schedule before the handler call, and interest is
     *      withdrawn from the handler that just paid out the principal.
     */
    function withdrawTokenAndInterest(address token, uint64 scheduleId, uint256 withdrawalAmount)
        external
        override
        whenUserMutationsAllowed
        nonReentrant
    {
        (uint256 routeIndex, ITokenHandler tokenHandler) = _withdrawToken(token, scheduleId, withdrawalAmount);
        _checkTokenYieldsInterest(token, routeIndex);
        _withdrawInterest(ITokenLending(address(tokenHandler)), token, routeIndex);
    }

    /**
     * @inheritdoc IDcaManager
     * @dev Moves no cash. The interest already sits in the handler's lending position, so raising this
     *      schedule's claim over it is a storage write; the accrued-interest call only reads, and never
     *      redeems, mints, or transfers. On a market that accrues lazily that read also pokes the accrual.
     */
    function topUpFromInterest(address token, uint64 scheduleId, uint256 amount) external override nonReentrant {
        DcaSchedule storage dcaSchedule = _callersSchedule(token, scheduleId);
        uint256 routeIndex = dcaSchedule.routeIndex;
        _checkTokenYieldsInterest(token, routeIndex);

        uint256 accruedInterest = ITokenLending(address(_handler(token, routeIndex))).getAccruedInterest(
            msg.sender, _lockedPrincipal(msg.sender, token, routeIndex)
        );
        if (accruedInterest == 0) revert DcaManager__NoInterestToTopUpWith(token, routeIndex);
        if (amount > accruedInterest) {
            revert DcaManager__TopUpExceedsAccruedInterest(token, routeIndex, amount, accruedInterest);
        }

        uint256 tokenBalance = dcaSchedule.tokenBalance;
        uint256 purchaseAmount = dcaSchedule.purchaseAmount;
        uint128 newTokenBalance = (tokenBalance + amount).toUint128();
        // The credit must buy at least one more purchase than the balance could already fund, so
        // interest cannot be moved over in dust. A schedule that spends nothing per purchase can
        // never clear that bar, and has nothing to top up for.
        if (purchaseAmount == 0 || newTokenBalance / purchaseAmount == tokenBalance / purchaseAmount) {
            revert DcaManager__TopUpDoesNotFundAnotherPurchase(token, scheduleId, amount);
        }

        dcaSchedule.tokenBalance = newTokenBalance;
        emit DcaManager__ScheduleToppedUpFromInterest(msg.sender, token, scheduleId, amount);
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /// @inheritdoc IDcaManager
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata routeIndexes)
        external
        override
        whenUserMutationsAllowed
        nonReentrant
    {
        uint256 numOfPairs = _requirePairedWithdrawalArrays(tokens, routeIndexes);
        for (uint256 i; i < numOfPairs; ++i) {
            address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(tokens[i], routeIndexes[i]);
            if (tokenHandlerAddress == address(0)) continue;
            // Skip idle routes so a mixed idle+lending call still withdraws interest
            // from the indexes that yield. Unassigned pairs already continued above.
            if (!_tokenYieldsInterest(routeIndexes[i])) continue;
            _withdrawInterest(ITokenLending(tokenHandlerAddress), tokens[i], routeIndexes[i]);
        }
    }

    /// @inheritdoc IDcaManager
    function withdrawRbtcFromTokenHandler(address token, uint256 routeIndex) external override nonReentrant {
        IPurchaseRbtc(address(_handler(token, routeIndex))).withdrawAccumulatedRbtc(msg.sender);
    }

    /// @inheritdoc IDcaManager
    function withdrawAllAccumulatedRbtc(address[] calldata tokens, uint256[] calldata routeIndexes) external override nonReentrant {
        uint256 numOfPairs = _requirePairedWithdrawalArrays(tokens, routeIndexes);
        for (uint256 i; i < numOfPairs; ++i) {
            address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(tokens[i], routeIndexes[i]);
            if (tokenHandlerAddress == address(0)) continue;
            IPurchaseRbtc handler = IPurchaseRbtc(tokenHandlerAddress);
            if (handler.getAccumulatedRbtcBalance(msg.sender) == 0) continue;
            handler.withdrawAccumulatedRbtc(msg.sender);
        }
    }

    // Swapper-only operations: protected-window activation and batch execution.

    /// @inheritdoc IDcaManager
    function activateProtectedPurchaseWindow() external override onlySwapper {
        uint256 userMutationsAllowedFromBlock = s_userMutationsAllowedFromBlock;
        if (block.number < userMutationsAllowedFromBlock) {
            revert DcaManager__ProtectedPurchaseWindowStillActive(userMutationsAllowedFromBlock);
        }

        userMutationsAllowedFromBlock = block.number + PROTECTED_PURCHASE_WINDOW_BLOCKS;
        s_userMutationsAllowedFromBlock = userMutationsAllowedFromBlock;
        emit DcaManager__ProtectedPurchaseWindowActivated(msg.sender, userMutationsAllowedFromBlock);
    }

    /// @inheritdoc IDcaManager
    function batchBuyRbtc(Batch calldata batch) external override onlySwapper {
        _batchBuyRbtc(batch);
    }

    /// @inheritdoc IDcaManager
    function batchBuyRbtcAcrossHandlers(Batch[] calldata batches) external override onlySwapper {
        uint256 numBatches = batches.length;
        if (numBatches == 0) revert DcaManager__EmptyHandlerBatches();

        for (uint256 i; i < numBatches; ++i) {
            _batchBuyRbtc(batches[i]);
        }
    }

    // Owner-only operations: protocol configuration.

    /// @inheritdoc IDcaManager
    function modifyMinPurchasePeriod(uint256 minPurchasePeriod)
        external
        override
        onlyOwner
        validateMinPurchasePeriod(minPurchasePeriod)
    {
        s_protocolSettings.minPurchasePeriod = minPurchasePeriod.toUint32();
        emit DcaManager__MinPurchasePeriodModified(minPurchasePeriod);
    }

    /// @inheritdoc IDcaManager
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external override onlyOwner {
        s_protocolSettings.maxSchedulesPerToken = maxSchedulesPerToken.toUint16();
        emit DcaManager__MaxSchedulesPerTokenModified(maxSchedulesPerToken);
    }

    /// @inheritdoc IDcaManager
    function setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) external override onlyOwner {
        if (minPurchaseAmount == 0) {
            revert DcaManager__TokenMinPurchaseAmountMustBeGreaterThanZero(token);
        }
        s_tokenMinPurchaseAmounts[token] = minPurchaseAmount;
        emit DcaManager__TokenMinPurchaseAmountSet(token, minPurchaseAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDcaManager
    function getDcaSchedule(address token, uint64 scheduleId) external view override returns (DcaSchedule memory) {
        DcaSchedule memory dcaSchedule = s_dcaSchedules[token][scheduleId];
        if (dcaSchedule.user == address(0)) revert DcaManager__InexistentSchedule(token, scheduleId);
        return dcaSchedule;
    }

    /// @inheritdoc IDcaManager
    function getDcaSchedules(address user, address token)
        external
        view
        override
        returns (uint64[] memory scheduleIds, DcaSchedule[] memory schedules)
    {
        scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        schedules = new DcaSchedule[](numOfSchedules);
        for (uint256 i; i < numOfSchedules; ++i) {
            schedules[i] = s_dcaSchedules[token][scheduleIds[i]];
        }
    }

    /// @inheritdoc IDcaManager
    function getSchedulesCreatedCount() external view override returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    /// @inheritdoc IDcaManager
    function getAccumulatedRbtcBalance(address user, address token, uint256 routeIndex)
        external
        view
        override
        returns (uint256)
    {
        return IPurchaseRbtc(address(_handler(token, routeIndex))).getAccumulatedRbtcBalance(user);
    }

    /// @inheritdoc IDcaManager
    function getInterestAccrued(address user, address token, uint256 routeIndex)
        external
        view
        override
        returns (uint256)
    {
        _checkTokenYieldsInterest(token, routeIndex);
        return ITokenLending(address(_handler(token, routeIndex))).quoteAccruedInterest(
            user, _lockedPrincipal(user, token, routeIndex)
        );
    }

    /// @inheritdoc IDcaManager
    function getUserMutationsAllowedFromBlock() external view override returns (uint256) {
        return s_userMutationsAllowedFromBlock;
    }

    /// @inheritdoc IDcaManager
    function canActivateProtectedPurchaseWindow() external view override returns (bool) {
        return block.number >= s_userMutationsAllowedFromBlock;
    }

    /// @inheritdoc IDcaManager
    function getMinPurchasePeriod() external view override returns (uint256) {
        return s_protocolSettings.minPurchasePeriod;
    }

    /// @inheritdoc IDcaManager
    function getMaxSchedulesPerToken() external view override returns (uint256) {
        return s_protocolSettings.maxSchedulesPerToken;
    }

    /// @inheritdoc IDcaManager
    function getTokenMinPurchaseAmount(address token) external view override returns (uint256) {
        return s_tokenMinPurchaseAmounts[token];
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The multi-line lock check (load unlock block, compare `block.number`, revert with that
     *      block) lives here for readability; `whenUserMutationsAllowed` is the single gate and
     *      calls this.
     */
    function _requireUserMutationsAllowed() private view {
        uint256 userMutationsAllowedFromBlock = s_userMutationsAllowedFromBlock;
        if (block.number < userMutationsAllowedFromBlock) {
            revert DcaManager__UserMutationsLocked(userMutationsAllowedFromBlock);
        }
    }

    /// @dev Validate one handler's batch, debit every named schedule, then call that handler.
    function _batchBuyRbtc(Batch calldata batch) private {
        uint256 numOfPurchases = batch.scheduleIds.length;
        if (numOfPurchases == 0) revert DcaManager__EmptyBatchPurchaseArrays();
        // What each row spends, and who it is bought for, are read from the schedule rather than taken
        // from the caller: the handler is paid the amounts the ledger holds and credits the accounts
        // the ledger names, so a batch can neither spend an amount a schedule does not hold nor send
        // one account's rBTC to another.
        address[] memory buyers = new address[](numOfPurchases);
        uint256[] memory purchaseAmounts = new uint256[](numOfPurchases);
        for (uint256 i; i < numOfPurchases; ++i) {
            (address buyer, uint256 schedulePurchaseAmount, uint256 scheduleRouteIndex) =
                _rBtcPurchaseChecksEffects(batch.token, batch.scheduleIds[i]);
            if (scheduleRouteIndex != batch.routeIndex) {
                revert DcaManager__RouteIndexMismatch(
                    batch.token, batch.scheduleIds[i], scheduleRouteIndex, batch.routeIndex
                );
            }
            buyers[i] = buyer;
            purchaseAmounts[i] = schedulePurchaseAmount;
        }
        IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex))).batchBuyRbtc(
            buyers, batch.scheduleIds, purchaseAmounts, batch.minRbtcOut
        );
    }

    /**
     * @dev Checks and effects of one purchase row, before the handler interaction.
     *      The `(token, scheduleId)` pair is the storage key, so a row of another stablecoin addresses
     *      nothing and is refused here rather than being debited by a handler that never held its
     *      funds — the stablecoin check is the lookup itself rather than a comparison after it. No
     *      owner is supplied by the caller either: the account credited with the purchase is read from
     *      the schedule. The route comparison stays with the caller, which is where its error is raised.
     * @return The schedule's owner, purchase amount and route index.
     */
    function _rBtcPurchaseChecksEffects(address token, uint64 scheduleId)
        private
        returns (address, uint256, uint256)
    {
        // Read the two packed schedule slots through a storage pointer instead of copying every field.
        DcaSchedule storage dcaSchedule = s_dcaSchedules[token][scheduleId];

        address buyer = dcaSchedule.user;
        if (buyer == address(0)) revert DcaManager__InexistentSchedule(token, scheduleId);

        if (dcaSchedule.paused) revert DcaManager__SchedulePaused(token, scheduleId);

        uint256 cadenceAnchor = dcaSchedule.cadenceAnchor;
        uint256 purchasePeriod = dcaSchedule.purchasePeriod;

        // The first buy anchors today; whole-day periods keep every later due date on that midnight grid.
        uint256 newAnchor;
        unchecked {
            // Safe: modulo cannot exceed the timestamp and uint48 + uint32 cannot overflow uint256.
            // A future midnight exceeds block.timestamp; after eligibility, all results are at most today.
            uint256 currentDayStart = block.timestamp - (block.timestamp % 1 days);
            newAnchor = currentDayStart;

            if (cadenceAnchor != 0) {
                uint256 nextDue = cadenceAnchor + purchasePeriod;
                if (currentDayStart < nextDue) {
                    revert DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(
                        token, scheduleId, nextDue - block.timestamp
                    );
                }

                // Consume the newest due slot without rebasing the grid; rebasing would shift every
                // later due day whenever a multi-day purchase succeeds late.
                uint256 periodsElapsed = (currentDayStart - cadenceAnchor) / purchasePeriod;
                newAnchor = cadenceAnchor + periodsElapsed * purchasePeriod;
            }
        }

        uint96 purchaseAmount = dcaSchedule.purchaseAmount;
        uint128 tokenBalance = dcaSchedule.tokenBalance;
        uint256 routeIndex = dcaSchedule.routeIndex;
        if (purchaseAmount > tokenBalance) {
            revert DcaManager__ScheduleBalanceNotEnoughForPurchase(token, scheduleId, tokenBalance);
        }
        unchecked {
            tokenBalance -= purchaseAmount;
        }
        // No anchor log: purchases emit RbtcBought, and the new anchor follows from the prior one and the period.
        _storePurchaseProgress(dcaSchedule, tokenBalance, newAnchor.toUint48());
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, tokenBalance);

        return (buyer, purchaseAmount, routeIndex);
    }

    /**
     * @dev Both fields live in slot 0. They merge into one store only in their own frame; inlined into
     *      the caller the compiler splits them, which costs a full storage write on Rootstock.
     */
    function _storePurchaseProgress(DcaSchedule storage dcaSchedule, uint128 tokenBalance, uint48 cadenceAnchor)
        private
    {
        dcaSchedule.tokenBalance = tokenBalance;
        dcaSchedule.cadenceAnchor = cadenceAnchor;
    }

    /// @dev The single owner check for user mutators. A zero owner means the key addresses no schedule.
    function _callersSchedule(address token, uint64 scheduleId)
        private
        view
        returns (DcaSchedule storage dcaSchedule)
    {
        dcaSchedule = s_dcaSchedules[token][scheduleId];
        address owner = dcaSchedule.user;
        if (owner == address(0)) revert DcaManager__InexistentSchedule(token, scheduleId);
        if (owner != msg.sender) revert DcaManager__NotScheduleOwner(token, scheduleId, owner);
    }

    /**
     * @dev Swap-pop the id from the owner's token list. The supplied index must currently contain
     *      scheduleId.
     */
    function _removeScheduleId(address user, address token, uint64 scheduleId, uint256 index) private {
        uint64[] storage scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        if (index >= numOfSchedules || scheduleIds[index] != scheduleId) {
            revert DcaManager__ScheduleIdIndexMismatch(token, scheduleId, index);
        }

        // numOfSchedules > index >= 0 by the check above, so numOfSchedules >= 1.
        uint256 lastIndex;
        unchecked {
            lastIndex = numOfSchedules - 1;
        }
        if (index != lastIndex) scheduleIds[index] = scheduleIds[lastIndex];
        scheduleIds.pop();
    }

    /// @dev Purchase amount must be at least the token's configured minimum and at most `tokenBalance`.
    function _validatePurchaseAmount(
        address token,
        uint256 purchaseAmount,
        uint256 tokenBalance
    ) private view {
        uint256 minPurchaseAmount = s_tokenMinPurchaseAmounts[token];
        if (minPurchaseAmount == 0) {
            revert DcaManager__TokenMinPurchaseAmountNotSet(token);
        }

        if (purchaseAmount < minPurchaseAmount) {
            revert DcaManager__PurchaseAmountMustBeGreaterThanMinimum(token, minPurchaseAmount);
        }
        if (purchaseAmount > tokenBalance) {
            revert DcaManager__PurchaseAmountExceedsBalance(token, purchaseAmount, tokenBalance);
        }
    }

    /// @dev The period must meet the protocol minimum and preserve the midnight cadence grid.
    function _validatePurchasePeriod(uint256 purchasePeriod) private view {
        if (purchasePeriod < s_protocolSettings.minPurchasePeriod) {
            revert DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
        }
        if (purchasePeriod % 1 days != 0) revert DcaManager__PurchasePeriodMustBeWholeDays();
    }

    /// @dev Deposit amount must be greater than zero.
    function _validateDeposit(uint256 depositAmount) private pure {
        if (depositAmount == 0) revert DcaManager__DepositAmountMustBeGreaterThanZero();
    }

    /**
     * @dev Slot 0 and slot 1 of a new schedule. `routeIndex` is assigned before `purchasePeriod`:
     *      that order stores slot 0 once. Declaration order stores it twice.
     */
    function _storeNewSchedule(
        DcaSchedule storage created,
        uint128 deposit,
        uint32 period,
        uint32 route,
        address user,
        uint96 purchase
    ) private {
        created.tokenBalance = deposit;
        created.routeIndex = route;
        created.purchasePeriod = period;
        created.user = user;
        created.purchaseAmount = purchase;
    }

    /**
     * @dev Revert unless `tokens` and `routeIndexes` are a non-empty positional pair list.
     * @return numOfPairs The shared length of the two arrays.
     */
    function _requirePairedWithdrawalArrays(address[] calldata tokens, uint256[] calldata routeIndexes)
        private
        pure
        returns (uint256 numOfPairs)
    {
        numOfPairs = tokens.length;
        if (numOfPairs == 0) revert DcaManager__EmptyWithdrawalArrays();
        if (numOfPairs != routeIndexes.length) revert DcaManager__ArraysLengthMismatch();
    }

    /**
     * @dev Resolve the handler for a deposit, rejecting the call if governance paused deposits.
     *      Only `depositToken` and `createDcaSchedule` route through here, and both do so before
     *      any token moves, so a paused pair never takes cash it would have to refund. Every other
     *      caller keeps using `_handler`: purchases, edits, deletion, and withdrawals must stay
     *      available on a paused route.
     */
    function _handlerForDeposit(address token, uint256 routeIndex) private view returns (ITokenHandler) {
        ITokenHandler tokenHandler = _handler(token, routeIndex);
        if (i_operationsAdmin.areDepositsPaused(token, routeIndex)) {
            revert DcaManager__DepositsPaused(token, routeIndex);
        }
        return tokenHandler;
    }

    /// @dev Resolve the handler for a token and route. Reverts if none is assigned.
    function _handler(address token, uint256 routeIndex) private view returns (ITokenHandler) {
        address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(token, routeIndex);
        if (tokenHandlerAddress == address(0)) revert DcaManager__TokenNotAccepted(token, routeIndex);
        return ITokenHandler(tokenHandlerAddress);
    }

    /**
     * @dev Withdraw principal from one schedule. Debits the requested amount, not what the handler
     *      paid out. `type(uint256).max` means this schedule's whole `tokenBalance`.
     * @return routeIndex The schedule's stored route, captured before the handler call.
     * @return tokenHandler The handler that paid out, so a caller need not resolve it again.
     */
    function _withdrawToken(address token, uint64 scheduleId, uint256 withdrawalAmount)
        private
        returns (uint256 routeIndex, ITokenHandler tokenHandler)
    {
        DcaSchedule storage dcaSchedule = _callersSchedule(token, scheduleId);
        uint256 tokenBalance = dcaSchedule.tokenBalance;
        if (withdrawalAmount == type(uint256).max) withdrawalAmount = tokenBalance;
        if (withdrawalAmount == 0) revert DcaManager__WithdrawalAmountMustBeGreaterThanZero();
        if (withdrawalAmount > tokenBalance) {
            revert DcaManager__WithdrawalAmountExceedsBalance(token, withdrawalAmount, tokenBalance);
        }
        // Subtract the requested withdrawal amount, not the amount the handler paid out
        uint256 newTokenBalance;
        unchecked {
            newTokenBalance = tokenBalance - withdrawalAmount;
        }
        routeIndex = dcaSchedule.routeIndex;
        dcaSchedule.tokenBalance = newTokenBalance.toUint128();
        // Lending success means the external share claim was fully consumed; cash may still be net of
        // a fee. The measured return is deliberately unused for the principal debit.
        tokenHandler = _handler(token, routeIndex);
        tokenHandler.withdrawToken(msg.sender, withdrawalAmount);
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @dev Withdraw interest from an already-resolved lending handler.
     *      Callers must already have established that `routeIndex` is a lending
     *      route (`_checkTokenYieldsInterest` to revert, or `_tokenYieldsInterest`
     *      to skip). This helper does not re-check.
     */
    function _withdrawInterest(ITokenLending tokenLending, address token, uint256 routeIndex) private {
        tokenLending.withdrawInterest(msg.sender, _lockedPrincipal(msg.sender, token, routeIndex));
    }

    /**
     * @dev Sum locked principal for one user, token, and route. The ids are copied to memory once:
     *      they pack four to a word, and indexing the storage array would re-read its length and
     *      the id's word on every iteration.
     */
    function _lockedPrincipal(address user, address token, uint256 routeIndex)
        private
        view
        returns (uint256 lockedTokenAmount)
    {
        uint64[] memory scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        for (uint256 i; i < numOfSchedules; ++i) {
            DcaSchedule storage dcaSchedule = s_dcaSchedules[token][scheduleIds[i]];
            if (dcaSchedule.routeIndex == routeIndex) {
                lockedTokenAmount += dcaSchedule.tokenBalance;
            }
        }
    }

    /// @dev Revert unless `routeIndex` is a lending route.
    function _checkTokenYieldsInterest(address token, uint256 routeIndex) private view {
        if (!_tokenYieldsInterest(routeIndex)) revert DcaManager__TokenDoesNotYieldInterest(token);
    }

    /// @dev Whether a route index was registered as lending.
    function _tokenYieldsInterest(uint256 routeIndex) private view returns (bool) {
        return i_operationsAdmin.isLendingRoute(routeIndex);
    }
}
