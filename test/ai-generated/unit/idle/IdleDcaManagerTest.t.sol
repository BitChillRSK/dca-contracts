// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "test/unit/deployment/BaseDeploymentTest.t.sol";
import {DeployIdleHandler} from "script/DeployIdleHandler.s.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import "script/Constants.sol";

/**
 * @title IdleDcaManagerTest
 * @notice DcaManager paths against an idle handler assigned at index 0 with no protocol name.
 * @dev Goes through DeployMocSwaps (via BaseDeploymentTest) and DeployIdleHandler so both scripts are exercised.
 */
contract IdleDcaManagerTest is BaseDeploymentTest {
    address internal constant USER = address(0x4444);
    address internal constant SWAPPER = address(0x3333);

    MockStablecoin internal docToken;
    MockMocProxy internal mocProxy;
    IdleDocHandlerMoc internal handler;

    uint256 internal constant DEPOSIT = 200 ether;
    uint256 internal constant PURCHASE = 50 ether;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }
        super.setUp();

        handler = IdleDocHandlerMoc(
            payable(new DeployIdleHandler().run(helperConfig, address(operationsAdmin), address(dcaManager)))
        );
        docToken = MockStablecoin(helperConfig.getStablecoinAddress());
        mocProxy = MockMocProxy(helperConfig.getActiveNetworkConfig().mocProxyAddress);

        vm.startPrank(OWNER);
        operationsAdmin.addSwapper(SWAPPER);
        operationsAdmin.assignTokenHandler(address(docToken), IDLE_INDEX, address(handler));
        vm.stopPrank();

        vm.deal(address(mocProxy), 100 ether);
        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);

        docToken.mint(USER, 10_000 ether);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);
    }

    function test_createDcaSchedule_atIndexZero_depositsIdleDoc() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(docToken))[0];
        assertEq(schedule.routeIndex, IDLE_INDEX);
        assertEq(schedule.tokenBalance, DEPOSIT);
        assertEq(handler.getUsersIdleTokenBalance(USER), DEPOSIT);
        assertEq(docToken.balanceOf(address(handler)), DEPOSIT);
        assertFalse(operationsAdmin.isLendingRoute(IDLE_INDEX));
    }

    function test_buyAndWithdraw_spendIdleDoc() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(docToken), 0).scheduleId;

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(docToken), 0, scheduleId);

        assertGt(dcaManager.getAccumulatedRbtcBalance(USER, address(docToken), IDLE_INDEX), 0);
        assertEq(handler.getUsersIdleTokenBalance(USER), DEPOSIT - PURCHASE);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 0).tokenBalance, DEPOSIT - PURCHASE);

        uint256 userDocBefore = docToken.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), 0, scheduleId, DEPOSIT - PURCHASE);

        assertEq(docToken.balanceOf(USER), userDocBefore + DEPOSIT - PURCHASE);
        assertEq(handler.getUsersIdleTokenBalance(USER), 0);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 0).tokenBalance, 0);

        uint256 userRbtcBefore = USER.balance;
        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(docToken), IDLE_INDEX);
        assertGt(USER.balance, userRbtcBefore);
        assertEq(dcaManager.getAccumulatedRbtcBalance(USER, address(docToken), IDLE_INDEX), 0);
    }

    function test_interestCalls_atIndexZero_revert() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(docToken), 0).scheduleId;

        bytes memory encodedRevert =
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(docToken));

        vm.expectRevert(encodedRevert);
        dcaManager.getInterestAccrued(USER, address(docToken), IDLE_INDEX);

        address[] memory tokens = new address[](1);
        tokens[0] = address(docToken);
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = IDLE_INDEX;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, indexes);

        vm.prank(USER);
        vm.expectRevert(encodedRevert);
        dcaManager.withdrawTokenAndInterest(address(docToken), 0, scheduleId, MIN_PURCHASE_AMOUNT);
    }

    function test_withdrawAllAccumulatedInterest_skipsIdleAndWithdrawsLending() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        uint256 lendingIndex = address(sovrynHandler) != address(0) ? SOVRYN_INDEX : TROPYKUS_INDEX;
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(docToken), lendingIndex, docHandlerMocAddress);

        vm.prank(USER);
        docToken.approve(docHandlerMocAddress, type(uint256).max);
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, lendingIndex);

        vm.warp(block.timestamp + 365 days);
        _accrueLendingViewRate();

        uint256 interest = dcaManager.getInterestAccrued(USER, address(docToken), lendingIndex);
        assertGt(interest, 0);

        uint256 userDocBefore = docToken.balanceOf(USER);
        uint256 idleBalanceBefore = handler.getUsersIdleTokenBalance(USER);
        address[] memory tokens = new address[](1);
        tokens[0] = address(docToken);
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = IDLE_INDEX;
        indexes[1] = lendingIndex;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, indexes);

        assertEq(handler.getUsersIdleTokenBalance(USER), idleBalanceBefore);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 0).tokenBalance, DEPOSIT);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 1).tokenBalance, DEPOSIT);
        assertGt(docToken.balanceOf(USER), userDocBefore);
        assertLt(dcaManager.getInterestAccrued(USER, address(docToken), lendingIndex), interest);
    }

    /// @notice Interest locks only this route's principal: idle is excluded, same-route schedules are summed.
    function test_getInterestAccrued_sumsSameRouteAndIgnoresIdle() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        uint256 lendingIndex = address(sovrynHandler) != address(0) ? SOVRYN_INDEX : TROPYKUS_INDEX;
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(docToken), lendingIndex, docHandlerMocAddress);

        vm.startPrank(USER);
        docToken.approve(docHandlerMocAddress, type(uint256).max);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, lendingIndex);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, lendingIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        _accrueLendingViewRate();

        uint256 interest = dcaManager.getInterestAccrued(USER, address(docToken), lendingIndex);
        assertGt(interest, 0);
        // Counting only one lending schedule treats the other as yield (~DEPOSIT).
        // Counting idle as well locks 3*DEPOSIT against ~2*DEPOSIT lent → 0 interest.
        assertLt(interest, DEPOSIT);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 0).tokenBalance, DEPOSIT);
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(docToken))
        );
        dcaManager.getInterestAccrued(USER, address(docToken), IDLE_INDEX);
    }

    function test_withdrawTokenAndInterest_usesThatScheduleRoute() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        uint256 lendingIndex = address(sovrynHandler) != address(0) ? SOVRYN_INDEX : TROPYKUS_INDEX;
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(docToken), lendingIndex, docHandlerMocAddress);

        vm.prank(USER);
        docToken.approve(docHandlerMocAddress, type(uint256).max);
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, lendingIndex);

        IDcaManager.DcaDetails memory idleSchedule = dcaManager.getDcaSchedule(USER, address(docToken), 0);
        IDcaManager.DcaDetails memory lendingSchedule = dcaManager.getDcaSchedule(USER, address(docToken), 1);
        assertEq(idleSchedule.routeIndex, IDLE_INDEX);
        assertEq(lendingSchedule.routeIndex, lendingIndex);

        bytes memory encodedRevert =
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(docToken));
        vm.prank(USER);
        vm.expectRevert(encodedRevert);
        dcaManager.withdrawTokenAndInterest(address(docToken), 0, idleSchedule.scheduleId, MIN_PURCHASE_AMOUNT);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 0).tokenBalance, DEPOSIT);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 1).tokenBalance, DEPOSIT);

        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(docToken), 1, lendingSchedule.scheduleId, MIN_PURCHASE_AMOUNT);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 0).tokenBalance, DEPOSIT);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 1).tokenBalance, DEPOSIT - MIN_PURCHASE_AMOUNT);
    }

    /// @dev Tropykus views read `exchangeRateStored`; accrue so `getInterestAccrued` sees the warp.
    function _accrueLendingViewRate() internal {
        if (address(tropykusHandler) != address(0)) {
            tropykusHandler.i_kToken().exchangeRateCurrent();
        }
    }
}
