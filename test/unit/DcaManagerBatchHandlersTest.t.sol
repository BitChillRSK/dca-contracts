// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseMoc} from "../../src/interfaces/IPurchaseMoc.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {DeployIdleHandler} from "../../script/DeployIdleHandler.s.sol";
import {DeployLayerBankHandler} from "../../script/DeployLayerBankHandler.s.sol";
import "../Constants.sol";
import {scheduleAt} from "test/utils/ScheduleAt.sol";

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
            scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex);
        batch.scheduleIds = new uint64[](1);
        batch.purchaseAmounts = new uint256[](1);
        batch.token = address(stablecoin);
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
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 secondBalanceBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SECOND_SCHEDULE_INDEX).tokenBalance;

        _batchBuy(_twoHandlers());

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            firstBalanceBefore - AMOUNT_TO_SPEND
        );
        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SECOND_SCHEDULE_INDEX).tokenBalance,
            secondBalanceBefore - AMOUNT_TO_SPEND
        );
        assertGt(firstHandler.getAccumulatedRbtcBalance(USER), firstRbtcBefore);
        assertGt(otherHandler.getAccumulatedRbtcBalance(USER), secondRbtcBefore);
    }

    function testMalformedSecondGroupRollsBackFirstGroup() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 firstRbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);

        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](2);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        batches[1].token = address(stablecoin);
        batches[1].routeIndex = secondRouteIndex;

        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        _batchBuy(batches);

        IDcaManager.DcaSchedule memory firstAfter =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance);
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), firstRbtcBefore);
    }

    function testPausedSecondGroupRollsBackFirstGroup() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint64 secondId =
            scheduleAt(dcaManager, USER, address(stablecoin), SECOND_SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        dcaManager.setSchedulePaused(secondId, true);

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
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance);
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), 0);
    }

    function testSecondHandlerFailureRollsBackFirstHandlerInteraction() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        uint256 firstRbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        uint256 secondRbtcBefore = IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER);

        // The first handler is called; the second then fails inside the MoC interaction.
        vm.prank(secondHandler);
        stablecoin.approve(address(mocProxy), 0);

        IDcaManager.Batch[] memory batches = _twoHandlers();
        vm.expectRevert(IPurchaseMoc.PurchaseMoc__RedeemFreeDocFailed.selector);
        _batchBuy(batches);

        IDcaManager.DcaSchedule memory firstAfter =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondAfter =
            scheduleAt(dcaManager, USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance);
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(secondAfter.tokenBalance, secondBefore.tokenBalance);
        assertEq(secondAfter.lastPurchaseTimestamp, secondBefore.lastPurchaseTimestamp);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), firstRbtcBefore);
        assertEq(IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER), secondRbtcBefore);
    }

    /// @dev R51: a later batch's own minimum failing must undo the earlier handler's completed purchase,
    ///      the same way a paused row or a venue failure does.
    function testSecondGroupMinimumFailureRollsBackFirstGroup() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        uint256 firstRbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        uint256 secondRbtcBefore = IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER);

        // Only the second handler's batch carries an unreachable minimum; the first is a normal purchase.
        IDcaManager.Batch[] memory batches = _twoHandlers();
        batches[1].minRbtcOut = type(uint256).max;

        vm.prank(SWAPPER);
        (bool ok,) = address(dcaManager).call(abi.encodeCall(IDcaManager.batchBuyRbtcAcrossHandlers, (batches)));
        assertFalse(ok, "the bundle must fail on the second handler's minimum");

        IDcaManager.DcaSchedule memory firstAfter =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondAfter =
            scheduleAt(dcaManager, USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance, "the earlier handler's debit rolls back");
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(secondAfter.tokenBalance, secondBefore.tokenBalance);
        assertEq(secondAfter.lastPurchaseTimestamp, secondBefore.lastPurchaseTimestamp);
        assertEq(
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER),
            firstRbtcBefore,
            "the earlier handler's rBTC credit rolls back"
        );
        assertEq(IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER), secondRbtcBefore);

        // The same bundle without that minimum still goes through, so nothing was left in a stuck state.
        _batchBuy(_twoHandlers());
        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            firstBefore.tokenBalance - AMOUNT_TO_SPEND
        );
    }

    /// @dev Each batch carries its own minimum: one handler's bound must not be applied to another's output.
    function testEachGroupCarriesItsOwnMinimum() external {
        _requireTwoHandlers();

        // A minimum only the two handlers' outputs together could clear must still fail the batch it is on.
        IDcaManager.Batch[] memory probe = _twoHandlers();
        probe[0].minRbtcOut = type(uint256).max;
        vm.prank(SWAPPER);
        (bool ok, bytes memory returnData) =
            address(dcaManager).call(abi.encodeCall(IDcaManager.batchBuyRbtcAcrossHandlers, (probe)));
        assertFalse(ok);
        assertEq(bytes4(returnData), IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector);

        // Reading the first handler's own measured output back, a bundle that gives each batch a minimum it
        // can meet on its own succeeds.
        bytes memory args = new bytes(returnData.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = returnData[i + 4];
        }
        (uint256 firstMeasured,) = abi.decode(args, (uint256, uint256));

        IDcaManager.Batch[] memory batches = _twoHandlers();
        batches[0].minRbtcOut = firstMeasured;
        batches[1].minRbtcOut = 1;
        _batchBuy(batches);

        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), firstMeasured);
        assertGt(IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER), 0);
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

        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp, 0);
    }

    function testAllowlistedSwapperCanBuyOneHandler() external {
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        _batchBuy(batches);
        assertGt(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp, 0);
    }

    function testBotEoaCanStillCallOriginalBatchBuyRbtc() external {
        IDcaManager.Batch memory batch = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertGt(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp, 0);
    }
}
