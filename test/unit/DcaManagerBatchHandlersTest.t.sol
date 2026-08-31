// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseMoc} from "../../src/interfaces/IPurchaseMoc.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {DeployIdleHandler} from "../../script/DeployIdleHandler.s.sol";
import {DeployLayerBankHandler} from "../../script/DeployLayerBankHandler.s.sol";
import "../Constants.sol";

/**
 * @notice Exercises the integrated multi-handler purchase entry point.
 * @dev Two-handler cases need a second MoC route on Anvil (idle + LayerBank). The portable
 *      access-control, empty-input, one-handler, and direct-retry cases run on every harness lane.
 */
contract DcaManagerBatchHandlersTest is DcaDappTest {
    uint256 internal constant SECOND_SCHEDULE_INDEX = 1;

    address internal secondHandler;
    uint256 internal secondRouteIndex;
    bool internal twoHandlersReady;

    function setUp() public override {
        super.setUp();
        if (address(dcaManager) == address(0)) return;

        if (block.chainid == ANVIL_CHAIN_ID && isMocSwaps) {
            _deploySecondHandler();
        }
    }

    function _deploySecondHandler() private {
        if (isNone) {
            secondRouteIndex = LAYERBANK_INDEX;
            secondHandler = new DeployLayerBankHandler().deployMocksAndHandler(
                address(dcaManager), address(stablecoin), address(mocProxy), FEE_COLLECTOR, OWNER
            );
        } else {
            secondRouteIndex = IDLE_INDEX;
            secondHandler = new DeployIdleHandler().deployIdleDocHandlerMoc(
                DeployIdleHandler.DeployParams({
                    dcaManager: address(dcaManager),
                    tokenAddress: address(stablecoin),
                    mocProxy: address(mocProxy),
                    feeCollector: FEE_COLLECTOR,
                    initialOwner: OWNER
                })
            );
        }

        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), secondRouteIndex, secondHandler);

        // The local MoC mock pulls DOC from each handler.
        vm.prank(secondHandler);
        stablecoin.approve(address(mocProxy), type(uint256).max);

        vm.startPrank(USER);
        stablecoin.approve(secondHandler, AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, secondRouteIndex
        );
        vm.stopPrank();
        twoHandlersReady = true;
    }

    function _requireTwoHandlers() private {
        if (!twoHandlersReady) vm.skip(true);
    }

    function _oneRow(uint256 scheduleIndex, uint256 routeIndex)
        private
        view
        returns (IDcaManager.Batch memory batch)
    {
        IDcaManager.DcaSchedule memory schedule =
            dcaManager.getDcaSchedule(USER, address(stablecoin), scheduleIndex);
        batch.buyers = new address[](1);
        batch.scheduleIndexes = new uint256[](1);
        batch.scheduleIds = new uint64[](1);
        batch.purchaseAmounts = new uint256[](1);
        batch.buyers[0] = USER;
        batch.token = address(stablecoin);
        batch.scheduleIndexes[0] = scheduleIndex;
        batch.scheduleIds[0] = schedule.scheduleId;
        batch.purchaseAmounts[0] = schedule.purchaseAmount;
        batch.routeIndex = routeIndex;
    }

    function _twoHandlers() private view returns (IDcaManager.Batch[] memory batches) {
        batches = new IDcaManager.Batch[](2);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        batches[1] = _oneRow(SECOND_SCHEDULE_INDEX, secondRouteIndex);
    }

    function _batchBuy(IDcaManager.Batch[] memory batches) private {
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtcAcrossHandlers(batches);
    }

    function testGroupedPurchaseBuysThroughBothHandlers() external {
        _requireTwoHandlers();

        IPurchaseRbtc firstHandler = IPurchaseRbtc(address(stablecoinHandler));
        IPurchaseRbtc otherHandler = IPurchaseRbtc(secondHandler);
        uint256 firstRbtcBefore = firstHandler.getAccumulatedRbtcBalance(USER);
        uint256 secondRbtcBefore = otherHandler.getAccumulatedRbtcBalance(USER);
        uint256 firstBalanceBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 secondBalanceBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX).tokenBalance;

        _batchBuy(_twoHandlers());

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            firstBalanceBefore - AMOUNT_TO_SPEND
        );
        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX).tokenBalance,
            secondBalanceBefore - AMOUNT_TO_SPEND
        );
        assertGt(firstHandler.getAccumulatedRbtcBalance(USER), firstRbtcBefore);
        assertGt(otherHandler.getAccumulatedRbtcBalance(USER), secondRbtcBefore);
    }

    function testMalformedSecondGroupRollsBackFirstGroup() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 firstRbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);

        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](2);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        batches[1].token = address(stablecoin);
        batches[1].routeIndex = secondRouteIndex;

        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        _batchBuy(batches);

        IDcaManager.DcaSchedule memory firstAfter =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance);
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), firstRbtcBefore);
    }

    function testPausedSecondGroupRollsBackFirstGroup() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        uint64 secondId =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), SECOND_SCHEDULE_INDEX, secondId, true);

        IDcaManager.Batch[] memory batches = _twoHandlers();
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__SchedulePaused.selector,
                USER,
                address(stablecoin),
                secondId,
                SECOND_SCHEDULE_INDEX
            )
        );
        _batchBuy(batches);

        IDcaManager.DcaSchedule memory firstAfter =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance);
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), 0);
    }

    function testSecondHandlerFailureRollsBackFirstHandlerInteraction() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        uint256 firstRbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        uint256 secondRbtcBefore = IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER);

        // The first handler is called; the second then fails inside the MoC interaction.
        vm.prank(secondHandler);
        stablecoin.approve(address(mocProxy), 0);

        IDcaManager.Batch[] memory batches = _twoHandlers();
        vm.expectRevert(IPurchaseMoc.PurchaseMoc__RedeemFreeDocFailed.selector);
        _batchBuy(batches);

        IDcaManager.DcaSchedule memory firstAfter =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondAfter =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance);
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(secondAfter.tokenBalance, secondBefore.tokenBalance);
        assertEq(secondAfter.lastPurchaseTimestamp, secondBefore.lastPurchaseTimestamp);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), firstRbtcBefore);
        assertEq(IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER), secondRbtcBefore);
    }

    function testEmptyHandlersRevert() external {
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](0);
        vm.expectRevert(IDcaManager.DcaManager__EmptyHandlerBatches.selector);
        _batchBuy(batches);
    }

    function testNonSwapperCannotBuyHandlers() external {
        address attacker = makeAddr("bundle-frontrunner");
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__UnauthorizedSwapper.selector, attacker));
        dcaManager.batchBuyRbtcAcrossHandlers(batches);

        assertEq(dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp, 0);
    }

    function testAllowlistedSwapperCanBuyOneHandler() external {
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        _batchBuy(batches);
        assertGt(dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp, 0);
    }

    function testBotEoaCanStillCallOriginalBatchBuyRbtc() external {
        IDcaManager.Batch memory batch = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertGt(dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp, 0);
    }
}
