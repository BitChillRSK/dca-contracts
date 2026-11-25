// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./deployment/BaseDeploymentTest.t.sol";
import {DeployLayerBankHandler} from "../../script/DeployLayerBankHandler.s.sol";
import {LayerBankDocHandlerMoc} from "../../src/layerbank/LayerBankDocHandlerMoc.sol";
import {MockLayerBankAToken} from "../mocks/MockLayerBank.sol";
import {ILendingHandler} from "../../src/interfaces/ILendingHandler.sol";
import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import "../Constants.sol";
import {scheduleAt} from "test/utils/ScheduleAt.sol";

contract ResidualShareWithdrawAllInterestTest is BaseDeploymentTest {
    uint256 internal constant ROUTE_LENDING = 31;
    uint256 internal constant DEPOSIT = 400 ether;

    address internal constant USER = address(0x7777);

    MockStablecoin internal tokenImpaired;
    MockStablecoin internal tokenHealthy;

    LayerBankDocHandlerMoc internal handlerImpaired;
    LayerBankDocHandlerMoc internal handlerHealthy;

    MockLayerBankAToken internal aTokenImpaired;
    MockLayerBankAToken internal aTokenHealthy;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DOC_STRING);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked(DOC_STRING))) {
            vm.skip(true);
            return;
        }
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        super.setUp();

        tokenImpaired = MockStablecoin(helperConfig.getStablecoin());
        tokenHealthy = new MockStablecoin(OWNER);
        address mocProxy = helperConfig.getActiveNetworkConfig().mocProxy;

        DeployLayerBankHandler deployer = new DeployLayerBankHandler();
        handlerImpaired = LayerBankDocHandlerMoc(
            payable(deployer.deployMocksAndHandler(
                    address(dcaManager), address(tokenImpaired), mocProxy, makeAddr(FEE_COLLECTOR_STRING), OWNER
                ))
        );
        handlerHealthy = LayerBankDocHandlerMoc(
            payable(deployer.deployMocksAndHandler(
                    address(dcaManager), address(tokenHealthy), mocProxy, makeAddr(FEE_COLLECTOR_STRING), OWNER
                ))
        );

        aTokenImpaired = MockLayerBankAToken(address(handlerImpaired.i_aToken()));
        aTokenHealthy = MockLayerBankAToken(address(handlerHealthy.i_aToken()));

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(ROUTE_LENDING, true);
        dcaManager.setTokenMinPurchaseAmount(address(tokenHealthy), MIN_PURCHASE_AMOUNT);
        operationsAdmin.assignHandler(address(tokenImpaired), ROUTE_LENDING, address(handlerImpaired));
        operationsAdmin.assignHandler(address(tokenHealthy), ROUTE_LENDING, address(handlerHealthy));
        vm.stopPrank();

        // Advance 30 days before user entry so the market index is > 1e27 (as on live Rootstock).
        vm.warp(block.timestamp + 30 days);

        tokenImpaired.mint(USER, DEPOSIT);
        tokenHealthy.mint(USER, DEPOSIT);
        vm.startPrank(USER);
        tokenImpaired.approve(address(handlerImpaired), type(uint256).max);
        tokenHealthy.approve(address(handlerHealthy), type(uint256).max);
        dcaManager.createDcaSchedule(
            address(tokenImpaired), DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, ROUTE_LENDING
        );
        dcaManager.createDcaSchedule(
            address(tokenHealthy), DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, ROUTE_LENDING
        );
        vm.stopPrank();
    }

    function test_exitForfeitsResidualShare_soBulkInterestSkipsImpairedRoute() external {
        uint256 sharesBefore = handlerImpaired.getUserShares(USER);
        uint256 baseTs = block.timestamp + 90 days;
        uint256 chosenTs;
        for (uint256 offset = 0; offset < 1 days; offset += 1 hours) {
            vm.warp(baseTs + offset);
            uint256 idx = aTokenImpaired.getNormalizedIncome();
            if ((sharesBefore * idx) % 1e27 > idx / 2) {
                chosenTs = baseTs + offset;
                break;
            }
        }
        assertGt(chosenTs, 0);

        uint256 healthyInterest = dcaManager.getAccruedInterest(USER, address(tokenHealthy), ROUTE_LENDING);
        assertGt(healthyInterest, 4 ether);

        // 1. Reserve 1 becomes illiquid (cash redemptions revert, receipt-token transfers remain open).
        aTokenImpaired.setRevertOnBurn(true);

        // 2. User exits the illiquid route in-kind via `withdrawLendingShares`.
        vm.prank(USER);
        dcaManager.withdrawLendingShares(address(tokenImpaired), ROUTE_LENDING);

        assertEq(scheduleAt(dcaManager, USER, address(tokenImpaired), 0).tokenBalance, 0);
        assertEq(handlerImpaired.getUserShares(USER), 0, "one-share remainder must be forfeited");
        assertEq(dcaManager.getAccruedInterest(USER, address(tokenImpaired), ROUTE_LENDING), 0);

        // The same bulk claim pays healthy interest without attempting an impaired cash redemption.
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenHealthy);
        tokens[1] = address(tokenImpaired);
        uint256[] memory routeIndexes = new uint256[](2);
        routeIndexes[0] = ROUTE_LENDING;
        routeIndexes[1] = ROUTE_LENDING;

        uint256 userHealthyBalanceBefore = tokenHealthy.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
        assertEq(tokenHealthy.balanceOf(USER) - userHealthyBalanceBefore, healthyInterest);
        assertEq(aTokenImpaired.scaledBalanceOf(address(handlerImpaired)), 1, "forfeited share stays on handler");

        vm.expectRevert(abi.encodeWithSelector(ILendingHandler.LendingHandler__NoSharesToWithdraw.selector, USER));
        vm.prank(USER);
        dcaManager.withdrawLendingShares(address(tokenImpaired), ROUTE_LENDING);
    }
}
