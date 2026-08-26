// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "test/unit/deployment/BaseDeploymentTest.t.sol";
import {DeployLayerBankHandler} from "script/DeployLayerBankHandler.s.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import "script/Constants.sol";

/**
 * @title LayerBankDcaManagerTest
 * @notice DcaManager paths against a LayerBank handler assigned at index 1 on this test's admin.
 * @dev Goes through DeployMocSwaps (via BaseDeploymentTest) and DeployLayerBankHandler. Index 1
 *      overwrites Tropykus on this admin only; the shared harness is unchanged (PR 16).
 */
contract LayerBankDcaManagerTest is BaseDeploymentTest {
    uint256 internal constant LAYERBANK_INDEX = 1;

    address internal constant USER = address(0x4444);
    address internal constant SWAPPER = address(0x3333);

    MockStablecoin internal docToken;
    MockMocProxy internal mocProxy;
    LayerBankDocHandlerMoc internal handler;

    uint256 internal constant DEPOSIT = 200 ether;
    uint256 internal constant PURCHASE = 50 ether;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }
        super.setUp();

        handler = LayerBankDocHandlerMoc(
            payable(
                new DeployLayerBankHandler().deployMocksAndHandler(
                    address(dcaManager),
                    helperConfig.getStablecoinAddress(),
                    helperConfig.getActiveNetworkConfig().mocProxyAddress,
                    makeAddr(FEE_COLLECTOR_STRING),
                    operationsAdmin.owner()
                )
            )
        );
        docToken = MockStablecoin(helperConfig.getStablecoinAddress());
        mocProxy = MockMocProxy(helperConfig.getActiveNetworkConfig().mocProxyAddress);

        vm.startPrank(OWNER);
        operationsAdmin.addSwapper(SWAPPER);
        operationsAdmin.assignTokenHandler(address(docToken), LAYERBANK_INDEX, address(handler));
        vm.stopPrank();

        vm.deal(address(mocProxy), 100 ether);
        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);

        docToken.mint(USER, 10_000 ether);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);
    }

    function test_createDcaSchedule_atIndexOne_mintsLtokens() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, LAYERBANK_INDEX);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(docToken))[0];
        assertEq(schedule.lendingProtocolIndex, LAYERBANK_INDEX);
        assertEq(schedule.tokenBalance, DEPOSIT);
        assertGt(handler.getUserShares(USER), 0);
        assertEq(docToken.balanceOf(address(handler)), 0);
        assertTrue(operationsAdmin.isLendingRoute(LAYERBANK_INDEX));
    }

    function test_buyAndWithdraw_spendLayerBankDoc() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, LAYERBANK_INDEX);
        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(docToken), 0);

        uint256 lTokensBefore = handler.getUserShares(USER);

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(docToken), 0, scheduleId);

        assertGt(dcaManager.getAccumulatedRbtcBalance(USER, address(docToken), LAYERBANK_INDEX), 0);
        assertLt(handler.getUserShares(USER), lTokensBefore);
        assertEq(dcaManager.getScheduleTokenBalance(USER, address(docToken), 0), DEPOSIT - PURCHASE);

        uint256 userDocBefore = docToken.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), 0, scheduleId, DEPOSIT - PURCHASE);

        assertEq(docToken.balanceOf(USER), userDocBefore + DEPOSIT - PURCHASE);
        assertEq(dcaManager.getScheduleTokenBalance(USER, address(docToken), 0), 0);

        uint256 userRbtcBefore = USER.balance;
        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(docToken), LAYERBANK_INDEX);
        assertGt(USER.balance, userRbtcBefore);
        assertEq(dcaManager.getAccumulatedRbtcBalance(USER, address(docToken), LAYERBANK_INDEX), 0);
    }

    function test_interestGetter_atIndexOne_doesNotRevert() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, LAYERBANK_INDEX);

        uint256 interest = dcaManager.getInterestAccrued(USER, address(docToken), LAYERBANK_INDEX);
        assertEq(interest, 0);
    }
}
