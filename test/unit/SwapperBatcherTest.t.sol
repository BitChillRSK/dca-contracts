// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {SwapperBatcher} from "../../src/SwapperBatcher.sol";
import {ISwapperBatcher} from "../../src/interfaces/ISwapperBatcher.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {DeployIdleHandler} from "../../script/DeployIdleHandler.s.sol";
import {DeployLayerBankHandler} from "../../script/DeployLayerBankHandler.s.sol";
import {DeploySwapperBatcher} from "../../script/DeploySwapperBatcher.s.sol";
import {batchBuyOne} from "../utils/BatchBuyOne.sol";
import "../Constants.sol";

/**
 * @title SwapperBatcherTest
 * @notice R42: one cron tick forwards several `batchBuyRbtc` groups through `batchBuyRbtcGroups`.
 * @dev Two-handler cases need a second MoC route on Anvil (idle + LayerBank). Access-control,
 *      empty-input, and custody tests run on every harness lane.
 */
contract SwapperBatcherTest is DcaDappTest {
    uint256 internal constant SECOND_SCHEDULE_INDEX = 1;

    SwapperBatcher internal batcher;
    address internal secondHandler;
    uint256 internal secondRouteIndex;
    bool internal twoHandlersReady;

    function setUp() public override {
        super.setUp();
        if (address(dcaManager) == address(0)) return;

        batcher = new SwapperBatcher(address(dcaManager));
        vm.prank(OWNER);
        operationsAdmin.addSwapper(address(batcher));

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

        // Local MockMocProxy pulls DOC from the handler; DcaDappTest only approved the first one.
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
        if (!twoHandlersReady) {
            vm.skip(true);
        }
    }

    function _oneRow(
        uint256 scheduleIndex,
        uint256 routeIndex
    ) private view returns (ISwapperBatcher.Batch memory batch) {
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

    function _twoGroups() private view returns (ISwapperBatcher.Batch[] memory batches) {
        batches = new ISwapperBatcher.Batch[](2);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        batches[1] = _oneRow(SECOND_SCHEDULE_INDEX, secondRouteIndex);
    }

    function _batchBuy(ISwapperBatcher.Batch[] memory batches) private {
        vm.prank(SWAPPER);
        batcher.batchBuyRbtcGroups(batches);
    }

    /*//////////////////////////////////////////////////////////////
                         TWO HANDLERS, ONE TX
    //////////////////////////////////////////////////////////////*/

    function testBatcherPurchasesBothHandlersInOneTx() external {
        _requireTwoHandlers();

        IPurchaseRbtc firstHandler = IPurchaseRbtc(address(stablecoinHandler));
        IPurchaseRbtc otherHandler = IPurchaseRbtc(secondHandler);
        uint256 firstRbtcBefore = firstHandler.getAccumulatedRbtcBalance(USER);
        uint256 secondRbtcBefore = otherHandler.getAccumulatedRbtcBalance(USER);
        uint256 firstBalanceBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 secondBalanceBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX).tokenBalance;

        _batchBuy(_twoGroups());

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            firstBalanceBefore - AMOUNT_TO_SPEND,
            "first handler schedule was not purchased"
        );
        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX).tokenBalance,
            secondBalanceBefore - AMOUNT_TO_SPEND,
            "second handler schedule was not purchased"
        );
        assertGt(firstHandler.getAccumulatedRbtcBalance(USER), firstRbtcBefore, "first handler rBTC");
        assertGt(otherHandler.getAccumulatedRbtcBalance(USER), secondRbtcBefore, "second handler rBTC");
        assertGt(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp,
            0,
            "first lastPurchaseTimestamp"
        );
        assertGt(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX).lastPurchaseTimestamp,
            0,
            "second lastPurchaseTimestamp"
        );
    }

    function testSecondGroupRevertRollsBackTheFirst() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        uint256 firstRbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        uint256 secondRbtcBefore = IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER);

        ISwapperBatcher.Batch[] memory batches = new ISwapperBatcher.Batch[](2);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        batches[1].token = address(stablecoin);
        batches[1].routeIndex = secondRouteIndex;

        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        _batchBuy(batches);

        IDcaManager.DcaSchedule memory firstAfter =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory secondAfter =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX);
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance, "first tokenBalance rolled back");
        assertEq(
            firstAfter.lastPurchaseTimestamp,
            firstBefore.lastPurchaseTimestamp,
            "first lastPurchaseTimestamp rolled back"
        );
        assertEq(secondAfter.tokenBalance, secondBefore.tokenBalance, "second tokenBalance untouched");
        assertEq(
            secondAfter.lastPurchaseTimestamp,
            secondBefore.lastPurchaseTimestamp,
            "second lastPurchaseTimestamp untouched"
        );
        assertEq(
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER),
            firstRbtcBefore,
            "first handler rBTC rolled back"
        );
        assertEq(
            IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER),
            secondRbtcBefore,
            "second handler rBTC untouched"
        );
    }

    function testPausedScheduleInSecondGroupRollsBackTheFirst() external {
        _requireTwoHandlers();

        IDcaManager.DcaSchedule memory firstBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        uint64 secondId =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SECOND_SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), SECOND_SCHEDULE_INDEX, secondId, true);

        ISwapperBatcher.Batch[] memory batches = _twoGroups();
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
        assertEq(firstAfter.tokenBalance, firstBefore.tokenBalance, "pause in group 2 must roll back group 1");
        assertEq(firstAfter.lastPurchaseTimestamp, firstBefore.lastPurchaseTimestamp);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), 0);
        assertEq(IPurchaseRbtc(secondHandler).getAccumulatedRbtcBalance(USER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           ACCESS AND INPUT
    //////////////////////////////////////////////////////////////*/

    function testUnlistedBatcherRevertsUnauthorizedSwapper() external {
        SwapperBatcher unlisted = new SwapperBatcher(address(dcaManager));
        ISwapperBatcher.Batch[] memory batches = new ISwapperBatcher.Batch[](1);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);

        vm.prank(SWAPPER);
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__UnauthorizedSwapper.selector, address(unlisted))
        );
        unlisted.batchBuyRbtcGroups(batches);

        IDcaManager.DcaSchedule memory schedule =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, 0, "unlisted batcher must not purchase");
    }

    function testEmptyBatchesRevert() external {
        ISwapperBatcher.Batch[] memory batches = new ISwapperBatcher.Batch[](0);
        vm.expectRevert(ISwapperBatcher.SwapperBatcher__EmptyBatches.selector);
        _batchBuy(batches);
    }

    function testNonSwapperCannotDriveTheBatcher() external {
        address attacker = makeAddr("bundle-frontrunner");
        ISwapperBatcher.Batch[] memory batches = new ISwapperBatcher.Batch[](1);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapperBatcher.SwapperBatcher__UnauthorizedSwapper.selector, attacker)
        );
        batcher.batchBuyRbtcGroups(batches);

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp,
            0,
            "a public caller must not be able to consume a due schedule"
        );
    }

    function testAllowlistedSwapperCanDriveTheBatcher() external {
        ISwapperBatcher.Batch[] memory batches = new ISwapperBatcher.Batch[](1);
        batches[0] = _oneRow(SCHEDULE_INDEX, s_routeIndex);
        _batchBuy(batches);
        assertGt(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp,
            0,
            "the bot EOA must be able to call the allowlisted batcher"
        );
    }

    function testBotEoaCanStillBuyDirectly() external {
        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND, s_routeIndex);
        assertGt(dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp, 0);
    }

    function testConstructorRejectsEoa() external {
        address eoa = makeAddr("not-a-dca-manager");
        vm.expectRevert(
            abi.encodeWithSelector(ISwapperBatcher.SwapperBatcher__DcaManagerIsNotAContract.selector, eoa)
        );
        new SwapperBatcher(eoa);
    }

    function testConstructorRejectsZeroAddress() external {
        vm.expectRevert(
            abi.encodeWithSelector(ISwapperBatcher.SwapperBatcher__DcaManagerIsNotAContract.selector, address(0))
        );
        new SwapperBatcher(address(0));
    }

    function testBatcherPinsDcaManager() external {
        assertEq(batcher.i_dcaManager(), address(dcaManager));
        assertEq(batcher.i_operationsAdmin(), address(operationsAdmin));
    }

    function testDeployScriptDeploysOnAnvil() external {
        if (block.chainid != ANVIL_CHAIN_ID) vm.skip(true);
        address deployed = new DeploySwapperBatcher().run(address(dcaManager));
        assertNotEq(deployed, address(0));
        assertEq(SwapperBatcher(deployed).i_dcaManager(), address(dcaManager));
        assertEq(SwapperBatcher(deployed).i_operationsAdmin(), address(operationsAdmin));
        assertFalse(operationsAdmin.isSwapper(deployed), "deploy script must not addSwapper");
    }

    function testBatcherRejectsNativeValue() external {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(batcher).call{value: 1 ether}("");
        assertFalse(success, "batcher accepted native rBTC");
        assertEq(address(batcher).balance, 0);
    }
}
