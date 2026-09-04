// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {OperationsAdmin} from "./OperationsAdmin.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title DcaManager
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice User and swapper entry point: create and manage dollar-cost-averaging schedules.
 * @notice The maximum DCA frequency allowed is daily.
 * @dev Holds the schedule ledger and no funds. `s_dcaSchedules` is written only in this contract, and
 *      every external function that writes it takes `nonReentrant` as its first modifier, so the guard
 *      is checkable by grep rather than by reading each function. The two `onlySwapper` purchase paths
 *      are the deliberate exception: each is CEI-clean per handler, and only an allowlisted swapper
 *      reaches them.
 */
contract DcaManager is IDcaManager, BitChillOwnable, ReentrancyGuard {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Storage-only schedule shape. The public getters return `DcaSchedule`, adding the id back
     *      from the mapping key. Neither the id nor the owner is repeated here, keeping this value at
     *      two slots. Slot 0 contains every field a purchase reads or writes, so a purchase writes one
     *      slot. Slot 1 pairs `token` with a `uint96 purchaseAmount`; widening it would add a third slot.
     *      A live schedule always has a non-zero token, which is the existence sentinel.
     */
    struct StoredSchedule {
        uint128 tokenBalance;
        uint48 lastPurchaseTimestamp;
        bool paused;
        uint32 purchasePeriod;
        uint32 routeIndex;
        address token;
        uint96 purchaseAmount;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Constructor-pinned registry. There is no setter: swapping this address
    ///      would redirect every live schedule and bypass add-only route assignment.
    OperationsAdmin private immutable i_operationsAdmin;

    /**
     * @notice Every schedule, addressed by the id it was created with and the account that owns it.
     * @dev The owner is half the key rather than a field, which is what makes ownership unforgeable:
     *      a caller reaching `s_dcaSchedules[scheduleId][msg.sender]` cannot land on somebody else's
     *      schedule, so there is no owner check to write and none to forget. It also keeps the struct
     *      at two slots, since only the stablecoin has to be carried.
     */
    mapping(uint64 scheduleId => mapping(address user => StoredSchedule dcaSchedule)) private s_dcaSchedules;

    /**
     * @notice The ids each user holds for each stablecoin.
     * @dev The enumeration a flat key cannot provide on its own: `getDcaSchedules` and the
     *      max-schedules-per-token bound both need this list, so create and delete each write two
     *      structures. Both are cold paths, paid once by the user; the purchase path never reads it.
     */
    mapping(address user => mapping(address tokenDeposited => uint64[] scheduleIds)) private s_scheduleIds;

    ProtocolSettings private s_protocolSettings;
    mapping(address token => uint256) private s_tokenMinPurchaseAmounts; // Custom minimum purchase amounts per token

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Protocol minimum purchase period cannot be below one UTC day.
     */
    modifier validateMinPurchasePeriod(uint256 minPurchasePeriod) {
        if (minPurchasePeriod < 1 days) revert DcaManager__MinPurchasePeriodMustBeAtLeastOneDay();
        _;
    }

    /**
     * @dev Only addresses on the OperationsAdmin swapper allowlist.
     */
    modifier onlySwapper() {
        if (!i_operationsAdmin.isSwapper(msg.sender)) {
            revert DcaManager__UnauthorizedSwapper(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param operationsAdminAddress The OperationsAdmin this manager is permanently pinned to.
     * @param minPurchasePeriod Minimum time between purchases, in seconds. Cannot be below one UTC day.
     * @param maxSchedulesPerToken Maximum number of schedules a user may hold per token.
     * @param defaultMinPurchaseAmount Default minimum purchase amount for tokens with no override.
     * @param initialOwner Address that owns this contract immediately after deploy.
     */
    constructor(
        address operationsAdminAddress,
        uint256 minPurchasePeriod,
        uint256 maxSchedulesPerToken,
        uint256 defaultMinPurchaseAmount,
        address initialOwner
    ) BitChillOwnable(initialOwner) validateMinPurchasePeriod(minPurchasePeriod) {
        if (operationsAdminAddress.code.length == 0) {
            revert DcaManager__OperationsAdminIsNotAContract(operationsAdminAddress);
        }
        i_operationsAdmin = OperationsAdmin(operationsAdminAddress);
        s_protocolSettings = ProtocolSettings({
            minPurchasePeriod: minPurchasePeriod.toUint32(),
            maxSchedulesPerToken: maxSchedulesPerToken.toUint16(),
            defaultMinPurchaseAmount: defaultMinPurchaseAmount.toUint128(),
            scheduleNonce: 0
        });
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IDcaManager
     * @dev Widths are checked before the handler pull so an overflowing credit cannot move tokens.
     */
    function depositToken(uint64 scheduleId, uint256 depositAmount) external override nonReentrant {
        _validateDeposit(depositAmount);
        StoredSchedule storage dcaSchedule = _callersSchedule(scheduleId);
        address token = dcaSchedule.token;
        uint128 newTokenBalance = (uint256(dcaSchedule.tokenBalance) + depositAmount.toUint128()).toUint128();
        _handlerForDeposit(token, dcaSchedule.routeIndex).depositToken(msg.sender, depositAmount);
        dcaSchedule.tokenBalance = newTokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function updatePurchaseAmount(uint64 scheduleId, uint256 newPurchaseAmount) external override nonReentrant {
        StoredSchedule storage dcaSchedule = _callersSchedule(scheduleId);
        address token = dcaSchedule.token;
        uint96 newAmount = newPurchaseAmount.toUint96();
        _validatePurchaseAmount(token, newAmount, dcaSchedule.tokenBalance);
        uint256 previousPurchaseAmount = dcaSchedule.purchaseAmount;
        dcaSchedule.purchaseAmount = newAmount;
        emit DcaManager__PurchaseAmountUpdated(msg.sender, scheduleId, previousPurchaseAmount, newPurchaseAmount);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function updatePurchasePeriod(uint64 scheduleId, uint256 newPurchasePeriod) external override nonReentrant {
        StoredSchedule storage dcaSchedule = _callersSchedule(scheduleId);
        _validatePurchasePeriod(newPurchasePeriod);
        uint256 previousPurchasePeriod = dcaSchedule.purchasePeriod;
        dcaSchedule.purchasePeriod = newPurchasePeriod.toUint32();
        emit DcaManager__PurchasePeriodUpdated(msg.sender, scheduleId, previousPurchasePeriod, newPurchasePeriod);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function setSchedulePaused(uint64 scheduleId, bool paused) external override nonReentrant {
        StoredSchedule storage dcaSchedule = _callersSchedule(scheduleId);
        if (dcaSchedule.paused == paused) return;
        dcaSchedule.paused = paused;
        emit DcaManager__SchedulePauseSet(msg.sender, scheduleId, paused);
    }

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
        // A zero token is the empty-value sentinel for the id/user mapping and can never be live,
        // even if governance mistakenly assigned a handler to that pair.
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

        s_dcaSchedules[scheduleId][msg.sender] = StoredSchedule({
            tokenBalance: deposit,
            lastPurchaseTimestamp: 0,
            paused: false,
            purchasePeriod: period,
            routeIndex: route,
            token: token,
            purchaseAmount: purchase
        });
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
     */
    function deleteDcaSchedule(uint64 scheduleId) external override nonReentrant {
        StoredSchedule memory dcaSchedule = _callersSchedule(scheduleId);

        address token = dcaSchedule.token;
        uint256 tokenBalance = dcaSchedule.tokenBalance;
        uint256 routeIndex = dcaSchedule.routeIndex;

        // Both structures drop the schedule before the handler call: the schedule itself, and the id's
        // place in its owner's list for this token.
        _removeScheduleId(msg.sender, token, scheduleId);
        delete s_dcaSchedules[scheduleId][msg.sender];

        uint256 amountWithdrawn;
        if (tokenBalance > 0) {
            amountWithdrawn = _handler(token, routeIndex).withdrawToken(msg.sender, tokenBalance);
        }

        // The event reports what left the handler, which may be less than the schedule's tokenBalance.
        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, amountWithdrawn);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function withdrawToken(uint64 scheduleId, uint256 withdrawalAmount) external override nonReentrant {
        _withdrawToken(scheduleId, withdrawalAmount);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function batchBuyRbtc(Batch calldata batch) external override onlySwapper {
        _batchBuyRbtc(batch);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function batchBuyRbtcAcrossHandlers(Batch[] calldata batches) external override onlySwapper {
        uint256 numBatches = batches.length;
        if (numBatches == 0) revert DcaManager__EmptyHandlerBatches();

        for (uint256 i; i < numBatches; ++i) {
            _batchBuyRbtc(batches[i]);
        }
    }

    /**
     * @inheritdoc IDcaManager
     */
    function withdrawRbtcFromTokenHandler(address token, uint256 routeIndex) external override nonReentrant {
        IPurchaseRbtc(address(_handler(token, routeIndex))).withdrawAccumulatedRbtc(msg.sender);
    }

    /**
     * @inheritdoc IDcaManager
     */
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

    /**
     * @inheritdoc IDcaManager
     * @dev The route index is captured from the schedule before the handler call.
     */
    function withdrawTokenAndInterest(uint64 scheduleId, uint256 withdrawalAmount)
        external
        override
        nonReentrant
    {
        (address token, uint256 routeIndex) = _withdrawToken(scheduleId, withdrawalAmount);
        _checkTokenYieldsInterest(token, routeIndex);
        _withdrawInterest(ITokenLending(address(_handler(token, routeIndex))), token, routeIndex);
    }

    /**
     * @inheritdoc IDcaManager
     * @dev Moves no cash. The interest already sits in the handler's lending position, so raising this
     *      schedule's claim over it is a storage write; the accrued-interest call only reads, and never
     *      redeems, mints, or transfers. On a market that accrues lazily that read also pokes the accrual.
     */
    function topUpFromInterest(uint64 scheduleId, uint256 amount) external override nonReentrant {
        StoredSchedule storage dcaSchedule = _callersSchedule(scheduleId);
        address token = dcaSchedule.token;
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

    /**
     * @inheritdoc IDcaManager
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata routeIndexes)
        external
        override
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

    /**
     * @inheritdoc IDcaManager
     */
    function modifyMinPurchasePeriod(uint256 minPurchasePeriod)
        external
        override
        onlyOwner
        validateMinPurchasePeriod(minPurchasePeriod)
    {
        s_protocolSettings.minPurchasePeriod = minPurchasePeriod.toUint32();
        emit DcaManager__MinPurchasePeriodModified(minPurchasePeriod);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external override onlyOwner {
        s_protocolSettings.maxSchedulesPerToken = maxSchedulesPerToken.toUint16();
        emit DcaManager__MaxSchedulesPerTokenModified(maxSchedulesPerToken);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function modifyDefaultMinPurchaseAmount(uint256 defaultMinPurchaseAmount) external override onlyOwner {
        s_protocolSettings.defaultMinPurchaseAmount = defaultMinPurchaseAmount.toUint128();
        emit DcaManager__DefaultMinPurchaseAmountModified(defaultMinPurchaseAmount);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) external override onlyOwner {
        s_tokenMinPurchaseAmounts[token] = minPurchaseAmount;
        emit DcaManager__TokenMinPurchaseAmountSet(token, minPurchaseAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IDcaManager
     */
    function getDcaSchedule(address user, uint64 scheduleId) external view override returns (DcaSchedule memory) {
        StoredSchedule memory dcaSchedule = s_dcaSchedules[scheduleId][user];
        if (dcaSchedule.token == address(0)) revert DcaManager__InexistentSchedule(user, scheduleId);
        return _toDcaSchedule(scheduleId, dcaSchedule);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getDcaSchedules(address user, address token)
        external
        view
        override
        returns (DcaSchedule[] memory schedules)
    {
        uint64[] storage scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        schedules = new DcaSchedule[](numOfSchedules);
        for (uint256 i; i < numOfSchedules; ++i) {
            uint64 scheduleId = scheduleIds[i];
            schedules[i] = _toDcaSchedule(scheduleId, s_dcaSchedules[scheduleId][user]);
        }
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getOperationsAdminAddress() external view override returns (address) {
        return address(i_operationsAdmin);
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getMinPurchasePeriod() external view override returns (uint256) {
        return s_protocolSettings.minPurchasePeriod;
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getMaxSchedulesPerToken() external view override returns (uint256) {
        return s_protocolSettings.maxSchedulesPerToken;
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getSchedulesCreatedCount() external view override returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getDefaultMinPurchaseAmount() external view override returns (uint256) {
        return s_protocolSettings.defaultMinPurchaseAmount;
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getTokenMinPurchaseAmount(address token) external view override returns (uint256 minPurchaseAmount, bool customMinAmountSet) {
        uint256 customAmount = s_tokenMinPurchaseAmounts[token];
        customMinAmountSet = customAmount != 0;
        minPurchaseAmount = customMinAmountSet ? customAmount : s_protocolSettings.defaultMinPurchaseAmount;
    }

    /**
     * @inheritdoc IDcaManager
     */
    function getAccumulatedRbtcBalance(address user, address token, uint256 routeIndex)
        external
        view
        override
        returns (uint256)
    {
        return IPurchaseRbtc(address(_handler(token, routeIndex))).getAccumulatedRbtcBalance(user);
    }

    /**
     * @inheritdoc IDcaManager
     */
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

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Validate one handler's batch, debit every named schedule, then call that handler.
     */
    function _batchBuyRbtc(Batch calldata batch) private {
        uint256 numOfPurchases = batch.scheduleIds.length;
        if (numOfPurchases == 0) revert DcaManager__EmptyBatchPurchaseArrays();
        if (numOfPurchases != batch.buyers.length) revert DcaManager__ArraysLengthMismatch();
        // What each row spends is read from its schedule, never taken from the caller, so the handler
        // is paid the amounts the ledger holds and a batch cannot spend one the schedule does not.
        uint256[] memory purchaseAmounts = new uint256[](numOfPurchases);
        for (uint256 i; i < numOfPurchases; ++i) {
            (uint256 schedulePurchaseAmount, uint256 scheduleRouteIndex) =
                _rBtcPurchaseChecksEffects(batch.scheduleIds[i], batch.buyers[i], batch.token);
            if (scheduleRouteIndex != batch.routeIndex) {
                revert DcaManager__RouteIndexMismatch(
                    batch.buyers[i], batch.token, batch.scheduleIds[i], scheduleRouteIndex, batch.routeIndex
                );
            }
            purchaseAmounts[i] = schedulePurchaseAmount;
        }
        IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex))).batchBuyRbtc(
            batch.buyers, batch.scheduleIds, purchaseAmounts, batch.minRbtcOut
        );
    }

    /**
     * @dev Resolve one of the caller's schedules by id. There is no ownership check here and none is
     *      possible to omit elsewhere: `msg.sender` is half the key, so a caller naming another
     *      account's schedule reads an empty struct and is refused as an id they do not hold. A live
     *      schedule always has a non-zero `token`.
     */
    function _callersSchedule(uint64 scheduleId) private view returns (StoredSchedule storage dcaSchedule) {
        dcaSchedule = s_dcaSchedules[scheduleId][msg.sender];
        if (dcaSchedule.token == address(0)) revert DcaManager__InexistentSchedule(msg.sender, scheduleId);
    }

    /**
     * @dev Put a stored schedule into the shape the getters return, which is the stored fields plus the
     *      half of its key that storage does not repeat.
     */
    function _toDcaSchedule(uint64 scheduleId, StoredSchedule memory dcaSchedule)
        private
        pure
        returns (DcaSchedule memory)
    {
        return DcaSchedule({
            scheduleId: scheduleId,
            tokenBalance: dcaSchedule.tokenBalance,
            lastPurchaseTimestamp: dcaSchedule.lastPurchaseTimestamp,
            paused: dcaSchedule.paused,
            purchasePeriod: dcaSchedule.purchasePeriod,
            routeIndex: dcaSchedule.routeIndex,
            token: dcaSchedule.token,
            purchaseAmount: dcaSchedule.purchaseAmount
        });
    }

    /**
     * @dev Take one id out of its owner's list for a token, by swap-pop. The scan is bounded by the
     *      max-schedules-per-token setting. Reverting when the id is absent keeps a desync between the
     *      two structures from popping a live schedule's id instead; it is unreachable while they agree,
     *      because an owned schedule is always listed under its own owner and token.
     */
    function _removeScheduleId(address user, address token, uint64 scheduleId) private {
        uint64[] storage scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        for (uint256 i; i < numOfSchedules; ++i) {
            if (scheduleIds[i] == scheduleId) {
                uint256 lastIndex = numOfSchedules - 1;
                if (i != lastIndex) scheduleIds[i] = scheduleIds[lastIndex];
                scheduleIds.pop();
                return;
            }
        }
        revert DcaManager__InexistentSchedule(user, scheduleId);
    }

    /**
     * @dev Purchase amount must be at least the token (or default) minimum and at most `tokenBalance`.
     */
    function _validatePurchaseAmount(
        address token,
        uint256 purchaseAmount,
        uint256 tokenBalance
    ) private view {
        uint256 minPurchaseAmount = s_tokenMinPurchaseAmounts[token];
        if (minPurchaseAmount == 0) {
            minPurchaseAmount = s_protocolSettings.defaultMinPurchaseAmount;
        }

        if (purchaseAmount < minPurchaseAmount) {
            revert DcaManager__PurchaseAmountMustBeGreaterThanMinimum(token, minPurchaseAmount);
        }
        if (purchaseAmount > tokenBalance) {
            revert DcaManager__PurchaseAmountExceedsBalance(token, purchaseAmount, tokenBalance);
        }
    }

    /**
     * @dev Purchase period must be at least the protocol minimum.
     */
    function _validatePurchasePeriod(uint256 purchasePeriod) private view {
        if (purchasePeriod < s_protocolSettings.minPurchasePeriod) {
            revert DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
        }
    }

    /**
     * @dev Deposit amount must be greater than zero.
     */
    function _validateDeposit(uint256 depositAmount) private pure {
        if (depositAmount == 0) revert DcaManager__DepositAmountMustBeGreaterThanZero();
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
     * @dev Resolve the handler for a token and route. Reverts if none is assigned.
     */
    function _handler(address token, uint256 routeIndex) private view returns (ITokenHandler) {
        address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(token, routeIndex);
        if (tokenHandlerAddress == address(0)) revert DcaManager__TokenNotAccepted(token, routeIndex);
        return ITokenHandler(tokenHandlerAddress);
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

    /**
     * @dev Checks and effects of one purchase row, before the handler interaction.
     *      The `(scheduleId, buyer)` pair is the storage key, so a row naming a schedule the buyer does
     *      not hold reads as an empty struct and is refused here rather than debiting anything. The
     *      stablecoin is checked for the same reason the key used to guarantee it: a schedule of
     *      another token must not be debited while the handler for this batch's token does the buying.
     *      The route comparison stays with the caller, which is where its error is raised.
     * @return The schedule's purchase amount and route index.
     */
    function _rBtcPurchaseChecksEffects(uint64 scheduleId, address buyer, address token)
        private
        returns (uint256, uint256)
    {
        StoredSchedule storage dcaScheduleStorage = s_dcaSchedules[scheduleId][buyer];
        StoredSchedule memory dcaSchedule = dcaScheduleStorage;

        if (dcaSchedule.token == address(0)) revert DcaManager__InexistentSchedule(buyer, scheduleId);
        if (dcaSchedule.token != token) {
            revert DcaManager__ScheduleTokenMismatch(buyer, scheduleId, token, dcaSchedule.token);
        }

        if (dcaSchedule.paused) revert DcaManager__SchedulePaused(buyer, token, scheduleId);

        uint256 lastPurchaseTimestamp = dcaSchedule.lastPurchaseTimestamp;
        uint256 purchasePeriod = dcaSchedule.purchasePeriod;

        // After the first purchase, the schedule is eligible once the UTC day of last + period has started
        if (lastPurchaseTimestamp != 0) {
            uint256 currentDayStart = block.timestamp - (block.timestamp % 1 days);
            uint256 nextDueTimestamp = lastPurchaseTimestamp + purchasePeriod;
            uint256 nextPurchaseDayStart = nextDueTimestamp - (nextDueTimestamp % 1 days);
            if (currentDayStart < nextPurchaseDayStart) {
                revert DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(nextPurchaseDayStart - block.timestamp);
            }
        }

        if (dcaSchedule.purchaseAmount > dcaSchedule.tokenBalance) {
            revert DcaManager__ScheduleBalanceNotEnoughForPurchase(
                buyer, scheduleId, token, dcaSchedule.tokenBalance
            );
        }
        dcaSchedule.tokenBalance -= dcaSchedule.purchaseAmount;
        dcaScheduleStorage.tokenBalance = dcaSchedule.tokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, dcaSchedule.tokenBalance);

        // Anchor the next due date to the schedule's own cadence, so the wanted periodicity survives
        // a delayed purchase or a schedule that was paused or ran out of stablecoin and was resumed with
        // a new deposit. Floor periodsElapsed at 1 so that the purchase isn't blocked when a full period
        // has elapsed in calendar days but not in seconds. This is fine since the purchase being eligible
        // was already checked above.
        uint256 newTimestamp;
        if (lastPurchaseTimestamp == 0) {
            newTimestamp = block.timestamp;
        } else {
            uint256 periodsElapsed = (block.timestamp - lastPurchaseTimestamp) / purchasePeriod;
            if (periodsElapsed == 0) periodsElapsed = 1;
            // The last purchase timestamp is anchored to the time of day of the first purchase to avoid drift
            newTimestamp = lastPurchaseTimestamp + periodsElapsed * purchasePeriod;
        }
        dcaScheduleStorage.lastPurchaseTimestamp = newTimestamp.toUint48();
        emit DcaManager__LastPurchaseTimestampUpdated(token, scheduleId, newTimestamp);

        return (dcaSchedule.purchaseAmount, dcaSchedule.routeIndex);
    }

    /**
     * @dev Withdraw principal from one schedule. Debits the requested amount, not what the handler
     *      paid out. `type(uint256).max` means this schedule's whole `tokenBalance`.
     * @return token The schedule's stablecoin, and `routeIndex` its stored route, both captured
     *         before the handler call.
     */
    function _withdrawToken(uint64 scheduleId, uint256 withdrawalAmount)
        private
        returns (address token, uint256 routeIndex)
    {
        StoredSchedule storage dcaSchedule = _callersSchedule(scheduleId);
        token = dcaSchedule.token;
        uint256 tokenBalance = dcaSchedule.tokenBalance;
        if (withdrawalAmount == type(uint256).max) withdrawalAmount = tokenBalance;
        if (withdrawalAmount == 0) revert DcaManager__WithdrawalAmountMustBeGreaterThanZero();
        if (withdrawalAmount > tokenBalance) {
            revert DcaManager__WithdrawalAmountExceedsBalance(token, withdrawalAmount, tokenBalance);
        }
        // Subtract the requested withdrawal amount, not the amount the handler paid out
        uint256 newTokenBalance = tokenBalance - withdrawalAmount;
        routeIndex = dcaSchedule.routeIndex;
        dcaSchedule.tokenBalance = newTokenBalance.toUint128();
        // `withdrawToken()`'s return value (what the handler actually paid out) is deliberately unused
        _handler(token, routeIndex).withdrawToken(msg.sender, withdrawalAmount);
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @dev Sum locked principal for one user, token, and route without copying the schedule array.
     */
    function _lockedPrincipal(address user, address token, uint256 routeIndex)
        private
        view
        returns (uint256 lockedTokenAmount)
    {
        uint64[] storage scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        for (uint256 i; i < numOfSchedules; ++i) {
            // `routeIndex` and `tokenBalance` share slot 0, so each schedule costs one read here.
            StoredSchedule storage dcaSchedule = s_dcaSchedules[scheduleIds[i]][user];
            if (dcaSchedule.routeIndex == routeIndex) {
                lockedTokenAmount += dcaSchedule.tokenBalance;
            }
        }
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
     * @dev Whether a route index was registered as lending.
     */
    function _tokenYieldsInterest(uint256 routeIndex) private view returns (bool) {
        return i_operationsAdmin.isLendingRoute(routeIndex);
    }

    /**
     * @dev Revert unless `routeIndex` is a lending route.
     */
    function _checkTokenYieldsInterest(address token, uint256 routeIndex) private view {
        if (!_tokenYieldsInterest(routeIndex)) revert DcaManager__TokenDoesNotYieldInterest(token);
    }
}
