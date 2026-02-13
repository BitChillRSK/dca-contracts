// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {OperationsAdmin} from "./OperationsAdmin.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title DCA Manager
 * @author BitChill team: Ynyesto (GitHub: @ynyesto)
 * @notice Entry point for the DCA dApp. Create and manage DCA schedules. 
 */
contract DcaManager is IDcaManager, Ownable, ReentrancyGuard {
    
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    OperationsAdmin private s_operationsAdmin;

    /**
     * @notice Each user may create different schedules with one or more stablecoins
     */
    mapping(address user => mapping(address tokenDeposited => DcaDetails[] usersDcaSchedules)) private s_dcaSchedules;
    uint256 private s_minPurchasePeriod; // Minimum time between purchases
    uint256 private s_maxSchedulesPerToken; // Maximum number of schedules per stablecoin
    uint256 private s_defaultMinPurchaseAmount; // Default minimum purchase amount for all tokens
    mapping(address token => uint256) private s_tokenMinPurchaseAmounts; // Custom minimum purchase amounts per token

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice validate the schedule index
     * @param user the user address to validate the schedule for
     * @param token the token address
     * @param scheduleIndex the schedule index
     */
    modifier validateScheduleIndex(address user, address token, uint256 scheduleIndex) {
        if (scheduleIndex >= s_dcaSchedules[user][token].length) {
            revert DcaManager__InexistentScheduleIndex();
        }
        _;
    }

    /**
     * @notice only allow swapper role
     */
    modifier onlySwapper() {
        if (!s_operationsAdmin.hasRole(s_operationsAdmin.SWAPPER_ROLE(), msg.sender)) {
            revert DcaManager__UnauthorizedSwapper(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param operationsAdminAddress the address of the admin operations contract
     * @param minPurchasePeriod the minimum time between purchases (in seconds)
     * @param maxSchedulesPerToken the maximum number of schedules allowed per token
     * @param defaultMinPurchaseAmount the default minimum purchase amount for all tokens
     */
    constructor(address operationsAdminAddress, uint256 minPurchasePeriod, uint256 maxSchedulesPerToken, uint256 defaultMinPurchaseAmount) Ownable() {
        s_operationsAdmin = OperationsAdmin(operationsAdminAddress);
        s_minPurchasePeriod = minPurchasePeriod;
        s_maxSchedulesPerToken = maxSchedulesPerToken;
        s_defaultMinPurchaseAmount = defaultMinPurchaseAmount;
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param depositAmount the amount of stablecoin to deposit
     */
    function depositToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 depositAmount)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        _validateDeposit(depositAmount);
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        uint256 newTokenBalance = dcaSchedule.tokenBalance + depositAmount;
        dcaSchedule.tokenBalance = newTokenBalance;
        _handler(token, dcaSchedule.lendingProtocolIndex).depositToken(msg.sender, depositAmount);
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param purchaseAmount the amount of stablecoin to swap periodically for rBTC
     * @notice the amount cannot be greater than or equal to half of the deposited amount
     */
    function setPurchaseAmount(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 purchaseAmount)
        external
        override
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        _validatePurchaseAmount(token, purchaseAmount, dcaSchedule.tokenBalance);
        dcaSchedule.purchaseAmount = purchaseAmount;
        emit DcaManager__PurchaseAmountSet(msg.sender, scheduleId, purchaseAmount);
    }

    /**
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param purchasePeriod the time (in seconds) between rBTC purchases for each user
     * @notice the period
     */
    function setPurchasePeriod(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 purchasePeriod)
        external
        override
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        _validatePurchasePeriod(purchasePeriod);
        dcaSchedule.purchasePeriod = purchasePeriod;
        emit DcaManager__PurchasePeriodSet(msg.sender, scheduleId, purchasePeriod);
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract, set the period and the amount for purchases
     * @param token: the token address of stablecoin to deposit
     * @param depositAmount: the amount of stablecoin to deposit
     * @param purchaseAmount: the amount of stablecoin to swap periodically for rBTC
     * @param purchasePeriod: the time (in seconds) between rBTC purchases for each user
     * @param lendingProtocolIndex: the lending protocol, if any, where the token will be deposited to generate yield
     */
    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 lendingProtocolIndex
    ) external override {
        _validatePurchasePeriod(purchasePeriod);
        _validateDeposit(depositAmount);
        _validatePurchaseAmount(token, purchaseAmount, depositAmount);
        _handler(token, lendingProtocolIndex).depositToken(msg.sender, depositAmount);

        DcaDetails[] storage schedules = s_dcaSchedules[msg.sender][token];
        uint256 numOfSchedules = schedules.length;
        if (numOfSchedules == s_maxSchedulesPerToken) {
            revert DcaManager__MaxSchedulesPerTokenReached(token);
        }

        bytes32 scheduleId =
            keccak256(abi.encodePacked(msg.sender, token, block.timestamp, numOfSchedules));

        DcaDetails memory dcaSchedule = DcaDetails(
            depositAmount,
            purchaseAmount,
            purchasePeriod,
            0, // lastPurchaseTimestamp
            scheduleId,
            lendingProtocolIndex
        );

        schedules.push(dcaSchedule);
        emit DcaManager__DcaScheduleCreated(
            msg.sender, 
            token,
            scheduleId, 
            depositAmount, 
            purchaseAmount, 
            purchasePeriod, 
            lendingProtocolIndex
        );
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract, set the period and the amount for purchases
     * @notice if the purchase or deposit amounts, or the purchase period are set to 0, they don't get updated
     * @param token: the token address of stablecoin to deposit
     * @param scheduleIndex: the index of the schedule to create or update
     * @param scheduleId: the schedule id for validation
     * @param depositAmount: the amount of stablecoin to add to the existing schedule (final token balance for the schedule is the previous balance + depositAmount)
     * @param purchaseAmount: the amount of stablecoin to swap periodically for rBTC
     * @param purchasePeriod: the time (in seconds) between rBTC purchases for each user
     */
    function updateDcaSchedule(
        address token,
        uint256 scheduleIndex,
        bytes32 scheduleId,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod
    ) external override validateScheduleIndex(msg.sender, token, scheduleIndex) {
        DcaDetails[] storage schedules = s_dcaSchedules[msg.sender][token];
        DcaDetails memory dcaSchedule = schedules[scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);

        if (purchasePeriod > 0) {
            _validatePurchasePeriod(purchasePeriod);
            dcaSchedule.purchasePeriod = purchasePeriod;
        }
        if (depositAmount > 0) {
            dcaSchedule.tokenBalance += depositAmount;
            _handler(token, dcaSchedule.lendingProtocolIndex).depositToken(msg.sender, depositAmount);
        }
        if (purchaseAmount > 0) {
            _validatePurchaseAmount(token, purchaseAmount, dcaSchedule.tokenBalance);
            dcaSchedule.purchaseAmount = purchaseAmount;
        }

        schedules[scheduleIndex] = dcaSchedule;

        emit DcaManager__DcaScheduleUpdated(
            msg.sender,
            token,
            dcaSchedule.scheduleId,
            dcaSchedule.tokenBalance,
            dcaSchedule.purchaseAmount,
            dcaSchedule.purchasePeriod
        );
    }

    /**
     * @notice delete a DCA schedule
     * @param token: the token of the schedule to delete
     * @param scheduleIndex: the index of the schedule to delete
     * @param scheduleId: the id of the schedule to delete for validation
     */
    function deleteDcaSchedule(address token, uint256 scheduleIndex, bytes32 scheduleId) external override 
        validateScheduleIndex(msg.sender, token, scheduleIndex)
        nonReentrant
    {
        DcaDetails[] storage schedules = s_dcaSchedules[msg.sender][token];
        
        DcaDetails memory dcaSchedule = schedules[scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);

        uint256 tokenBalance = dcaSchedule.tokenBalance;
        uint256 lendingProtocolIndex = dcaSchedule.lendingProtocolIndex;

        // Remove the schedule by poping the last one and overwriting the one to delete with it
        uint256 lastIndex = schedules.length - 1;
        if (scheduleIndex != lastIndex) {
            schedules[scheduleIndex] = schedules[lastIndex];
        }
        schedules.pop();

        if (tokenBalance > 0) {
            _handler(token, lendingProtocolIndex).withdrawToken(msg.sender, tokenBalance);
        }

        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, tokenBalance);
    }

    /**
     * @notice withdraw amount for DCA from the contract
     * @param token: the token to withdraw
     * @param scheduleIndex: the index of the schedule to withdraw from
     * @param scheduleId: the schedule id for validation
     * @param withdrawalAmount: the amount to withdraw
     */
    function withdrawToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 withdrawalAmount)
        external
        override
        nonReentrant
    {
        _withdrawToken(token, scheduleIndex, scheduleId, withdrawalAmount);
    }

    /**
     * @notice buy rBTC for a user
     * @param buyer: the address of the user
     * @param token: the token to buy rBTC with
     * @param scheduleIndex: the index of the schedule to buy rBTC from
     * @param scheduleId: the id of the schedule to buy rBTC from
     */
    function buyRbtc(address buyer, address token, uint256 scheduleIndex, bytes32 scheduleId)
        external
        override
        nonReentrant
        onlySwapper
    {
        (uint256 purchaseAmount, uint256 lendingProtocolIndex) =
            _rBtcPurchaseChecksEffects(buyer, token, scheduleIndex, scheduleId);

        IPurchaseRbtc(address(_handler(token, lendingProtocolIndex))).buyRbtc(
            buyer, scheduleId, purchaseAmount
        );
    }

    /**
     * @param buyers the array of addresses of the users on behalf of whom rBTC is going to be bought
     * @notice a buyer may be featured more than once in the buyers array if two or more their schedules are due for a purchase
     * @notice we need to take extra care in the back end to not mismatch a user's address with a wrong DCA schedule
     * @param token the stablecoin that all users in the array will spend to purchase rBTC
     * @param scheduleIndexes the indexes of the DCA schedules that correspond to each user's purchase
     * @param purchaseAmounts the purchase amount that corresponds to each user's purchase
     * @param lendingProtocolIndex the lending protocol to withdraw the tokens from before purchasing
     * @notice the token and lending protocol are the same for all dca schedules in the batch.
     * @notice SWAPPER MUST NOT MIX SCHEDULES WITH DIFFERENT TOKENS OR LENDING PROTOCOLS IN THE SAME BATCH
     * @notice This is unchecked to save gas because access to this function is controlled by the onlySwapper modifier
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        address token,
        uint256[] calldata scheduleIndexes,
        bytes32[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 lendingProtocolIndex
    ) external override nonReentrant onlySwapper {
        uint256 numOfPurchases = buyers.length;
        if (numOfPurchases == 0) revert DcaManager__EmptyBatchPurchaseArrays();
        if (
            numOfPurchases != scheduleIndexes.length || numOfPurchases != scheduleIds.length
                || numOfPurchases != purchaseAmounts.length
        ) revert DcaManager__BatchPurchaseArraysLengthMismatch();
        for (uint256 i; i < numOfPurchases; ++i) {
            (uint256 purchaseAmount, ) = _rBtcPurchaseChecksEffects(buyers[i], token, scheduleIndexes[i], scheduleIds[i]);
            if (purchaseAmount != purchaseAmounts[i]) revert DcaManager__PurchaseAmountMismatch(buyers[i], token, scheduleIds[i], scheduleIndexes[i], purchaseAmount, purchaseAmounts[i]);
        }
        IPurchaseRbtc(address(_handler(token, lendingProtocolIndex))).batchBuyRbtc(
            buyers, scheduleIds, purchaseAmounts
        );
    }

    /**
     * @notice Users can withdraw the rBtc accumulated through all the DCA strategies created using a given stablecoin
     * @param token The token address of the stablecoin
     * @param lendingProtocolIndex The index of the lending protocol where the stablecoin is lent (0 if it is not lent)
     */
    function withdrawRbtcFromTokenHandler(address token, uint256 lendingProtocolIndex) external override nonReentrant {
        IPurchaseRbtc(address(_handler(token, lendingProtocolIndex))).withdrawAccumulatedRbtc(msg.sender);
    }

    /**
     * @notice Withdraw all of the rBTC accumulated by a user through their various DCA strategies
     * @param tokens Array of token addresses to withdraw rBTC from
     * @param lendingProtocolIndexes Array of lending protocol indexes where the user has positions
     */
    function withdrawAllAccumulatedRbtc(address[] calldata tokens, uint256[] calldata lendingProtocolIndexes) external override nonReentrant {
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < lendingProtocolIndexes.length; ++j) {
                address tokenHandlerAddress = s_operationsAdmin.getTokenHandler(tokens[i], lendingProtocolIndexes[j]);
                if (tokenHandlerAddress == address(0)) continue;
                IPurchaseRbtc handler = IPurchaseRbtc(tokenHandlerAddress);
                if (handler.getAccumulatedRbtcBalance(msg.sender) == 0) continue;
                handler.withdrawAccumulatedRbtc(msg.sender);
            }
        }
    }

    /**
     * @notice withdraw amount for DCA from the contract, as well as the yield generated across all DCA schedules
     * @param token: the token of which to withdraw the specified amount and yield
     * @param scheduleIndex: the index of the schedule to withdraw from
     * @param scheduleId: the schedule id for validation
     * @param withdrawalAmount: the amount to withdraw
     * @param lendingProtocolIndex: the lending protocol index
     */
    function withdrawTokenAndInterest(
        address token,
        uint256 scheduleIndex,
        bytes32 scheduleId,
        uint256 withdrawalAmount,
        uint256 lendingProtocolIndex
    ) external override nonReentrant {
        _withdrawToken(token, scheduleIndex, scheduleId, withdrawalAmount);
        _withdrawInterest(token, lendingProtocolIndex);
    }

    /**
     * @dev Users can withdraw the stablecoin interests accrued by the deposits they made
     * @param tokens Array of token addresses to withdraw interest from
     * @param lendingProtocolIndexes Array of lending protocol indexes to withdraw interest from
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata lendingProtocolIndexes)
        external
        override
        nonReentrant
    {
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < lendingProtocolIndexes.length; ++j) {
                address tokenHandlerAddress = s_operationsAdmin.getTokenHandler(tokens[i], lendingProtocolIndexes[j]);
                if (tokenHandlerAddress == address(0)) continue;
                _withdrawInterest(tokens[i], lendingProtocolIndexes[j]);
            }
        }
    }

    /**
     * @notice update the admin operations contract
     * @param operationsAdminAddress: the address of admin operations
     */
    function setOperationsAdmin(address operationsAdminAddress) external override onlyOwner {
        s_operationsAdmin = OperationsAdmin(operationsAdminAddress);
        emit DcaManager__OperationsAdminUpdated(operationsAdminAddress);
    }

    /**
     * @notice modify the minimum period between purchases
     * @param minPurchasePeriod: the new period
     */
    function modifyMinPurchasePeriod(uint256 minPurchasePeriod) external override onlyOwner {
        s_minPurchasePeriod = minPurchasePeriod;
        emit DcaManager__MinPurchasePeriodModified(minPurchasePeriod);
    }

    /**
     * @notice modify the maximum number of schedules per token
     * @param maxSchedulesPerToken: the new maximum number of schedules per token
     */
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external override onlyOwner {
        s_maxSchedulesPerToken = maxSchedulesPerToken;
        emit DcaManager__MaxSchedulesPerTokenModified(maxSchedulesPerToken);
    }

    /**
     * @notice modify the default minimum purchase amount for all tokens
     * @param defaultMinPurchaseAmount: the new default minimum purchase amount
     */
    function modifyDefaultMinPurchaseAmount(uint256 defaultMinPurchaseAmount) external override onlyOwner {
        s_defaultMinPurchaseAmount = defaultMinPurchaseAmount;
        emit DcaManager__DefaultMinPurchaseAmountModified(defaultMinPurchaseAmount);
    }

    /**
     * @notice set a custom minimum purchase amount for a specific token
     * @param token: the token address
     * @param minPurchaseAmount: the custom minimum purchase amount for this token
     */
    function setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) external override onlyOwner {
        s_tokenMinPurchaseAmounts[token] = minPurchaseAmount;
        emit DcaManager__TokenMinPurchaseAmountSet(token, minPurchaseAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice validate that the schedule id matches the schedule at the given index
     * @param scheduleId: the schedule id to validate
     * @param dcaScheduleScheduleId: the schedule id to validate against
     */
    function _validateScheduleId(bytes32 scheduleId, bytes32 dcaScheduleScheduleId) private pure {
        if (scheduleId != dcaScheduleScheduleId) revert DcaManager__ScheduleIdAndIndexMismatch();
    }

    /**
     * @notice validate that the purchase amount to be set is valid
     * @param token: the token spent on DCA
     * @param purchaseAmount: the purchase amount to validate
     * @param tokenBalance: the current balance of the token in that DCA schedule
     */
    function _validatePurchaseAmount(
        address token,
        uint256 purchaseAmount,
        uint256 tokenBalance
    ) private view {
        uint256 minPurchaseAmount = s_tokenMinPurchaseAmounts[token];
        if (minPurchaseAmount == 0) {
            minPurchaseAmount = s_defaultMinPurchaseAmount;
        }
        
        if (purchaseAmount < minPurchaseAmount) {
            revert DcaManager__PurchaseAmountMustBeGreaterThanMinimum(token, minPurchaseAmount);
        }
        /**
         * @notice Purchase amount must be at least twice the balance of the token in the contract to allow at least two DCA purchases
         */
        if (purchaseAmount > (tokenBalance) / 2) {
            revert DcaManager__PurchaseAmountMustBeLowerThanHalfOfBalance();
        }
    }

    /**
     * @notice validate the purchase period
     * @param purchasePeriod the purchase period to validate
     */
    function _validatePurchasePeriod(uint256 purchasePeriod) private view {
        if (purchasePeriod < s_minPurchasePeriod) revert DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract
     * @param depositAmount: the amount to deposit
     */
    function _validateDeposit(uint256 depositAmount) private pure {
        if (depositAmount == 0) revert DcaManager__DepositAmountMustBeGreaterThanZero();
    }

    /**
     * @notice get the token handler for a token and lending protocol index
     * @param token: the token
     * @param lendingProtocolIndex: the lending protocol index
     * @return the token handler
     */
    function _handler(address token, uint256 lendingProtocolIndex) private view returns (ITokenHandler) {
        address tokenHandlerAddress = s_operationsAdmin.getTokenHandler(token, lendingProtocolIndex);
        if (tokenHandlerAddress == address(0)) revert DcaManager__TokenNotAccepted(token, lendingProtocolIndex);
        return ITokenHandler(tokenHandlerAddress);
    }

    /**
     * @notice checks and effects of the purchase, before interactions take place
     * @param buyer: the address of the buyer
     * @param token: the token
     * @param scheduleIndex: the index of the schedule
     * @param scheduleId: the id of the schedule
     * @return the purchase amount and lending protocol index
     */
    function _rBtcPurchaseChecksEffects(address buyer, address token, uint256 scheduleIndex, bytes32 scheduleId)
        private
        validateScheduleIndex(buyer, token, scheduleIndex)
        returns (uint256, uint256)
    {
        DcaDetails storage dcaScheduleStorage = s_dcaSchedules[buyer][token][scheduleIndex];
        DcaDetails memory dcaSchedule = dcaScheduleStorage;

        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);

        // @notice: If this is not the first purchase for this schedule, check that period has elapsed before making a new purchase
        if (dcaSchedule.lastPurchaseTimestamp > 0 && block.timestamp - dcaSchedule.lastPurchaseTimestamp < dcaSchedule.purchasePeriod) {
            revert DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(
                dcaSchedule.lastPurchaseTimestamp + dcaSchedule.purchasePeriod - block.timestamp
            );
        }

        if (dcaSchedule.purchaseAmount > dcaSchedule.tokenBalance) {
            revert DcaManager__ScheduleBalanceNotEnoughForPurchase(scheduleIndex, scheduleId, token, dcaSchedule.tokenBalance);
        }
        dcaSchedule.tokenBalance -= dcaSchedule.purchaseAmount;
        dcaScheduleStorage.tokenBalance = dcaSchedule.tokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, dcaSchedule.tokenBalance);

        // @notice: this way purchases are possible with the wanted periodicity even if 
        // - a previous purchase was delayed
        // - the schedule run out of stablecoin and was resumed later with a new deposit
        uint256 periodsElapsed = (block.timestamp - dcaSchedule.lastPurchaseTimestamp) / dcaSchedule.purchasePeriod;
        unchecked {
            dcaSchedule.lastPurchaseTimestamp = dcaSchedule.lastPurchaseTimestamp == 0
                ? block.timestamp
                : dcaSchedule.lastPurchaseTimestamp + periodsElapsed * dcaSchedule.purchasePeriod;
        }
        dcaScheduleStorage.lastPurchaseTimestamp = dcaSchedule.lastPurchaseTimestamp;
        emit DcaManager__LastPurchaseTimestampUpdated(token, scheduleId, dcaSchedule.lastPurchaseTimestamp);

        return (dcaSchedule.purchaseAmount, dcaSchedule.lendingProtocolIndex);
    }

    /**
     * @notice withdraw a token from a DCA schedule
     * @param token: the token to withdraw
     * @param scheduleIndex: the index of the schedule
     * @param scheduleId: the schedule id for validation
     * @param withdrawalAmount: the amount to withdraw
     */
    function _withdrawToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 withdrawalAmount) 
        private
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        if (withdrawalAmount == 0) revert DcaManager__WithdrawalAmountMustBeGreaterThanZero();
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        uint256 tokenBalance = dcaSchedule.tokenBalance;
        if (withdrawalAmount > tokenBalance) {
            revert DcaManager__WithdrawalAmountExceedsBalance(token, withdrawalAmount, tokenBalance);
        }
        uint256 newTokenBalance = tokenBalance - withdrawalAmount;
        dcaSchedule.tokenBalance = newTokenBalance;
        _handler(token, dcaSchedule.lendingProtocolIndex).withdrawToken(msg.sender, withdrawalAmount);
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @notice withdraw interest from a lending protocol
     * @param token: the token to withdraw interest from
     * @param lendingProtocolIndex: the lending protocol index
     */
    function _withdrawInterest(address token, uint256 lendingProtocolIndex) private {
        _checkTokenYieldsInterest(token, lendingProtocolIndex);
        ITokenHandler tokenHandler = _handler(token, lendingProtocolIndex);
        DcaDetails[] memory dcaSchedules = s_dcaSchedules[msg.sender][token];
        uint256 lockedTokenAmount;
        for (uint256 i; i < dcaSchedules.length; ++i) {
            if (dcaSchedules[i].lendingProtocolIndex == lendingProtocolIndex) {
                lockedTokenAmount += dcaSchedules[i].tokenBalance;
            }
        }
        ITokenLending(address(tokenHandler)).withdrawInterest(msg.sender, lockedTokenAmount);
    }

    /**
     * @notice check if a token yields interest
     * @param token: the token to check
     * @param lendingProtocolIndex: the lending protocol index
     */
    function _checkTokenYieldsInterest(address token, uint256 lendingProtocolIndex) private view {
        bytes32 protocolNameHash =
            keccak256(abi.encodePacked(s_operationsAdmin.getLendingProtocolName(lendingProtocolIndex)));
        if (protocolNameHash == keccak256(abi.encodePacked(""))) revert DcaManager__TokenDoesNotYieldInterest(token);
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice get all DCA schedules for the caller
     * @param token: the token to get schedules for
     * @return the DCA schedules
     */
    function getMyDcaSchedules(address token) external view override returns (DcaDetails[] memory) {
        return getDcaSchedules(msg.sender, token);
    }

    /**
     * @notice get all DCA schedules for a specific user
     * @param user: the user to get schedules for
     * @param token: the token to get schedules for
     * @return the DCA schedules
     */
    function getDcaSchedules(address user, address token) public view override returns (DcaDetails[] memory) {
        return s_dcaSchedules[user][token];
    }

    /**
     * @notice get the token balance for a DCA schedule (caller's schedule)
     * @param token: the token to get the balance for
     * @param scheduleIndex: the index of the schedule
     * @return the token balance
     */
    function getMyScheduleTokenBalance(address token, uint256 scheduleIndex)
        external
        view
        override
        returns (uint256)
    {
        return getScheduleTokenBalance(msg.sender, token, scheduleIndex);
    }

    /**
     * @notice get the token balance for a DCA schedule
     * @param user: the user to get the balance for
     * @param token: the token to get the balance for
     * @param scheduleIndex: the index of the schedule
     * @return the token balance
     */
    function getScheduleTokenBalance(address user, address token, uint256 scheduleIndex)
        public
        view
        override
        validateScheduleIndex(user, token, scheduleIndex)
        returns (uint256)
    {
        return s_dcaSchedules[user][token][scheduleIndex].tokenBalance;
    }

    /**
     * @notice get the purchase amount for a DCA schedule (caller's schedule)
     * @param token: the token to get the purchase amount for
     * @param scheduleIndex: the index of the schedule
     * @return the purchase amount
     */
    function getMySchedulePurchaseAmount(address token, uint256 scheduleIndex)
        external
        view
        override
        returns (uint256)
    {
        return getSchedulePurchaseAmount(msg.sender, token, scheduleIndex);
    }

    /**
     * @notice get the purchase amount for a DCA schedule
     * @param user: the user to get the purchase amount for
     * @param token: the token to get the purchase amount for
     * @param scheduleIndex: the index of the schedule
     * @return the purchase amount
     */
    function getSchedulePurchaseAmount(address user, address token, uint256 scheduleIndex)
        public
        view
        override
        validateScheduleIndex(user, token, scheduleIndex)
        returns (uint256)
    {
        return s_dcaSchedules[user][token][scheduleIndex].purchaseAmount;
    }

    /**
     * @notice get the purchase period for a DCA schedule (caller's schedule)
     * @param token: the token to get the purchase period for
     * @param scheduleIndex: the index of the schedule
     * @return the purchase period
     */
    function getMySchedulePurchasePeriod(address token, uint256 scheduleIndex)
        external
        view
        override
        returns (uint256)
    {
        return getSchedulePurchasePeriod(msg.sender, token, scheduleIndex);
    }

    /**
     * @notice get the purchase period for a DCA schedule
     * @param user: the user to get the purchase period for
     * @param token: the token to get the purchase period for
     * @param scheduleIndex: the index of the schedule
     * @return the purchase period
     */
    function getSchedulePurchasePeriod(address user, address token, uint256 scheduleIndex)
        public
        view
        override
        validateScheduleIndex(user, token, scheduleIndex)
        returns (uint256)
    {
        return s_dcaSchedules[user][token][scheduleIndex].purchasePeriod;
    }

    /**
     * @notice get the schedule id for a DCA schedule (caller's schedule)
     * @param token: the token to get the schedule id for
     * @param scheduleIndex: the index of the schedule
     * @return the schedule id
     */
    function getMyScheduleId(address token, uint256 scheduleIndex) external view override returns (bytes32) {
        return getScheduleId(msg.sender, token, scheduleIndex);
    }

    /**
     * @notice get the schedule id for a DCA schedule
     * @param user: the user to get the schedule id for
     * @param token: the token to get the schedule id for
     * @param scheduleIndex: the index of the schedule
     * @return the schedule id
     */
    function getScheduleId(address user, address token, uint256 scheduleIndex)
        public
        view
        override
        validateScheduleIndex(user, token, scheduleIndex)
        returns (bytes32)
    {
        return s_dcaSchedules[user][token][scheduleIndex].scheduleId;
    }

    /**
     * @notice get the admin operations address
     * @return the admin operations address
     */
    function getOperationsAdminAddress() external view override returns (address) {
        return address(s_operationsAdmin);
    }

    /**
     * @notice get the minimum purchase period
     * @return the minimum purchase period
     */
    function getMinPurchasePeriod() external view override returns (uint256) {
        return s_minPurchasePeriod;
    }

    /**
     * @notice get the maximum number of schedules per token
     * @return the maximum number of schedules per token
     */
    function getMaxSchedulesPerToken() external view override returns (uint256) {
        return s_maxSchedulesPerToken;
    }

    /**
     * @notice get the default minimum purchase amount for all tokens
     * @return the default minimum purchase amount
     */
    function getDefaultMinPurchaseAmount() external view override returns (uint256) {
        return s_defaultMinPurchaseAmount;
    }

    /**
     * @notice get the minimum purchase amount for a specific token
     * @param token: the token address
     * @return minPurchaseAmount the minimum purchase amount for this token
     * @return customMinAmountSet whether a custom amount is set (false means using default)
     */
    function getTokenMinPurchaseAmount(address token) external view override returns (uint256 minPurchaseAmount, bool customMinAmountSet) {
        uint256 customAmount = s_tokenMinPurchaseAmounts[token];
        customMinAmountSet = customAmount != 0;
        minPurchaseAmount = customMinAmountSet ? customAmount : s_defaultMinPurchaseAmount;
    }

    /**
     * @notice get the interest accrued by the caller with a given stablecoin in a given lending protocol
     * @param token: the token to get the interest for
     * @param lendingProtocolIndex: the lending protocol index to get the interest for
     * @return the interest accrued
     */
    function getMyInterestAccrued(address token, uint256 lendingProtocolIndex) external view override returns (uint256) {
        return getInterestAccrued(msg.sender, token, lendingProtocolIndex);
    }

    /**
     * @notice get the interest accrued by the caller with a given stablecoin in a given lending protocol
     * @param user: the user to get the interest for
     * @param token: the token to get the interest for
     * @param lendingProtocolIndex: the lending protocol index to get the interest for
     * @return the interest accrued
     */
    function getInterestAccrued(address user, address token, uint256 lendingProtocolIndex)
        public
        view
        override
        returns (uint256)
    {
        _checkTokenYieldsInterest(token, lendingProtocolIndex);
        ITokenHandler tokenHandler = _handler(token, lendingProtocolIndex);
        DcaDetails[] memory dcaSchedules = s_dcaSchedules[user][token];
        uint256 lockedTokenAmount;
        for (uint256 i; i < dcaSchedules.length; ++i) {
            if (dcaSchedules[i].lendingProtocolIndex == lendingProtocolIndex) {
                lockedTokenAmount += dcaSchedules[i].tokenBalance;
            }
        }
        return ITokenLending(address(tokenHandler)).getAccruedInterest(user, lockedTokenAmount);
    }
}
