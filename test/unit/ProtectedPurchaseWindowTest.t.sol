// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt, scheduleCount} from "test/utils/ScheduleAt.sol";

/**
 * @notice Coverage for the swapper-activated, five-block batch preparation window.
 */
contract ProtectedPurchaseWindowTest is DcaDappTest {
    event DcaManager__ProtectedPurchaseWindowActivated(address indexed swapper, uint256 userMutationsAllowedFromBlock);

    function testSwapperActivatesFiveBlockWindowAndEventIndexesOnlySwapper() external {
        assertEq(dcaManager.getUserMutationsAllowedFromBlock(), 0);
        assertTrue(dcaManager.canActivateProtectedPurchaseWindow());
        uint256 expectedAllowedFromBlock = block.number + 5;

        vm.recordLogs();
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();

        assertEq(dcaManager.getUserMutationsAllowedFromBlock(), expectedAllowedFromBlock);
        assertFalse(dcaManager.canActivateProtectedPurchaseWindow());
        bytes32 sig = DcaManager__ProtectedPurchaseWindowActivated.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics.length, 2, "only the swapper address is indexed");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), SWAPPER);
            assertEq(abi.decode(logs[i].data, (uint256)), expectedAllowedFromBlock);
            found = true;
        }
        assertTrue(found, "activation event not emitted");
    }

    function testOnlyCurrentSwapperCanActivate() external {
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__UnauthorizedSwapper.selector, USER));
        vm.prank(USER);
        dcaManager.activateProtectedPurchaseWindow();

        vm.prank(OWNER);
        operationsAdmin.revokeSwapper(SWAPPER);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__UnauthorizedSwapper.selector, SWAPPER));
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();
    }

    function testEveryBatchInvalidatingUserMutationIsLockedThroughFourthFollowingBlock() external {
        uint64 scheduleId = _scheduleId();
        uint256 allowedFromBlock = _activateWindow();
        bytes memory expectedRevert =
            abi.encodeWithSelector(IDcaManager.DcaManager__UserMutationsLocked.selector, allowedFromBlock);

        _assertUserCallRevertsLocked(
            abi.encodeCall(IDcaManager.updatePurchaseAmount, (address(stablecoin), scheduleId, AMOUNT_TO_SPEND)),
            expectedRevert
        );

        vm.roll(allowedFromBlock - 1);
        _assertUserCallRevertsLocked(
            abi.encodeCall(IDcaManager.updatePurchasePeriod, (address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD)),
            expectedRevert
        );
        _assertUserCallRevertsLocked(
            abi.encodeCall(IDcaManager.setSchedulePaused, (address(stablecoin), scheduleId, true)), expectedRevert
        );
        _assertUserCallRevertsLocked(
            abi.encodeCall(IDcaManager.deleteDcaSchedule, (address(stablecoin), scheduleId, type(uint256).max)),
            expectedRevert
        );
        _assertUserCallRevertsLocked(
            abi.encodeCall(IDcaManager.withdrawToken, (address(stablecoin), scheduleId, 1)), expectedRevert
        );
        _assertUserCallRevertsLocked(
            abi.encodeCall(IDcaManager.withdrawTokenAndInterest, (address(stablecoin), scheduleId, 1)), expectedRevert
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        _assertUserCallRevertsLocked(
            abi.encodeCall(IDcaManager.withdrawAllAccumulatedInterest, (tokens, routeIndexes)), expectedRevert
        );

        vm.roll(allowedFromBlock);
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
    }

    function testActivationCannotBeExtendedWhileLiveButCanReopenAfterExpiry() external {
        uint256 allowedFromBlock = _activateWindow();

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__ProtectedPurchaseWindowStillActive.selector, allowedFromBlock
            )
        );
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();

        vm.roll(allowedFromBlock);
        assertTrue(dcaManager.canActivateProtectedPurchaseWindow());
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();
        assertEq(dcaManager.getUserMutationsAllowedFromBlock(), allowedFromBlock + 5);
    }

    function testPreparedBatchPurchasesWhileOwnerMutationIsLocked() external {
        uint64 scheduleId = _scheduleId();
        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 allowedFromBlock = _activateWindow();

        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__UserMutationsLocked.selector, allowedFromBlock));
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND * 2);

        buyRbtcOne(scheduleId);
        assertLt(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, balanceBefore);
    }

    function testUnrelatedUserActionsAndGovernanceStayOpen() external {
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }

        uint64 scheduleId = _scheduleId();
        _activateWindow();

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), type(uint256).max);
        dcaManager.depositToken(address(stablecoin), scheduleId, 1);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();
        assertEq(scheduleCount(dcaManager, USER, address(stablecoin)), 2);
        uint64 secondScheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 1);

        vm.prank(OWNER);
        dcaManager.setMinPurchasePeriod(2 days);
        assertEq(dcaManager.getMinPurchasePeriod(), 2 days);
        vm.startPrank(OWNER);
        dcaManager.setMaxSchedulesPerToken(3);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), 1);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);

        buyRbtcOne(scheduleId);

        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = secondScheduleId;
        batches[0] = IDcaManager.Batch({
            scheduleIds: scheduleIds, token: address(stablecoin), routeIndex: s_routeIndex, minRbtcOut: 0
        });
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtcAcrossHandlers(batches);

        assertGt(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), 0);
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);

        vm.warp(block.timestamp + MIN_PURCHASE_PERIOD);
        buyRbtcOne(scheduleId);
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
    }

    function testInterestTopUpStaysOpen() external onlyLendingLane {
        updateExchangeRate(200 days);
        uint64 scheduleId = _scheduleId();
        uint256 accruedInterest = dcaManager.getAccruedInterest(USER, address(stablecoin), s_routeIndex);
        assertGt(accruedInterest, 0);

        uint256 slack = accruedInterest / 4;
        if (slack > AMOUNT_TO_SPEND / 10) slack = AMOUNT_TO_SPEND / 10;
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, slack);

        _activateWindow();
        vm.prank(USER);
        dcaManager.topUpFromInterest(address(stablecoin), scheduleId, slack);
    }

    function _scheduleId() private view returns (uint64) {
        return scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
    }

    function _activateWindow() private returns (uint256 allowedFromBlock) {
        allowedFromBlock = block.number + 5;
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();
    }

    function _assertUserCallRevertsLocked(bytes memory callData, bytes memory expectedRevert) private {
        vm.prank(USER);
        (bool success, bytes memory returnData) = address(dcaManager).call(callData);
        assertFalse(success);
        assertEq(returnData, expectedRevert);
    }
}
