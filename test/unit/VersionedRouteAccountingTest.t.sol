// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./deployment/BaseDeploymentTest.t.sol";
import {DeployLayerBankHandler} from "../../script/DeployLayerBankHandler.s.sol";
import {LayerBankDocHandlerMoc} from "../../src/layerbank/LayerBankDocHandlerMoc.sol";
import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import "../Constants.sol";

/**
 * @title VersionedRouteAccountingTest
 * @notice Two versioned lending routes backed by two distinct handlers keep independent
 *         principal and share accounting.
 * @dev **This is not a guard on R47's uniqueness check.** It passes with that check removed,
 *      because R47 makes the shared-handler state unconstructible through `assignTokenHandler`:
 *      once one address cannot back two pairs, no test driving the public API can reach the bug.
 *      The guards on the check itself are the `testHandlerAddressCannotBe*` cases in
 *      `OperationsAdminTest`, which do fail without it.
 *
 *      What this file covers is the remedy R47 forces on ops: when one handler per pair is the
 *      only legal shape, a fresh instance per route must still account correctly. DcaManager
 *      locks principal per route while a lending handler keys `s_shares` by user alone, so
 *      route v1's 400 DOC must never surface as route v2's yield against 100 DOC of locked
 *      principal. Handlers come from `DeployLayerBankHandler`, which gives each route its own
 *      Pool/aToken mocks.
 */
contract VersionedRouteAccountingTest is BaseDeploymentTest {
    uint256 internal constant ROUTE_V1 = 21;
    uint256 internal constant ROUTE_V2 = 22;
    uint256 internal constant DEPOSIT_V1 = 400 ether;
    uint256 internal constant DEPOSIT_V2 = 100 ether;

    address internal constant USER = address(0x5555);

    LayerBankDocHandlerMoc internal handlerV1;
    LayerBankDocHandlerMoc internal handlerV2;
    MockStablecoin internal docToken;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DOC_STRING);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }
        // Anvil only. This is a mock-accounting regression: it mints DOC to the user and relies on
        // the LayerBank Pool/aToken mocks to accrue and pay yield. On a fork the stablecoin is live
        // DOC (not mintable by this test) and there is no live protocol fact for it to learn.
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        super.setUp();

        address docTokenAddress = helperConfig.getStablecoinAddress();
        docToken = MockStablecoin(docTokenAddress);
        address mocProxyAddress = helperConfig.getActiveNetworkConfig().mocProxyAddress;

        DeployLayerBankHandler deployer = new DeployLayerBankHandler();
        handlerV1 = LayerBankDocHandlerMoc(
            payable(
                deployer.deployMocksAndHandler(
                    address(dcaManager), docTokenAddress, mocProxyAddress, makeAddr(FEE_COLLECTOR_STRING), OWNER
                )
            )
        );
        handlerV2 = LayerBankDocHandlerMoc(
            payable(
                deployer.deployMocksAndHandler(
                    address(dcaManager), docTokenAddress, mocProxyAddress, makeAddr(FEE_COLLECTOR_STRING), OWNER
                )
            )
        );

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(ROUTE_V1, true);
        operationsAdmin.registerRoute(ROUTE_V2, true);
        operationsAdmin.assignTokenHandler(docTokenAddress, ROUTE_V1, address(handlerV1));
        operationsAdmin.assignTokenHandler(docTokenAddress, ROUTE_V2, address(handlerV2));
        vm.stopPrank();

        docToken.mint(USER, DEPOSIT_V1 + DEPOSIT_V2);
        vm.startPrank(USER);
        docToken.approve(address(handlerV1), type(uint256).max);
        docToken.approve(address(handlerV2), type(uint256).max);
        dcaManager.createDcaSchedule(docTokenAddress, DEPOSIT_V1, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, ROUTE_V1);
        dcaManager.createDcaSchedule(docTokenAddress, DEPOSIT_V2, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, ROUTE_V2);
        vm.stopPrank();
    }

    /// @notice Two distinct handlers hold two distinct share balances; neither sees the other's principal.
    function testVersionedRoutesKeepSharesSeparate() external {
        assertGt(handlerV1.getUserShares(USER), 0);
        assertGt(handlerV2.getUserShares(USER), 0);
        // Shares track each route's own deposit, so the larger deposit holds the larger balance.
        assertGt(handlerV1.getUserShares(USER), handlerV2.getUserShares(USER));
        assertEq(operationsAdmin.getTokenHandler(address(docToken), ROUTE_V1), address(handlerV1), "route v1 handler");
        assertEq(operationsAdmin.getTokenHandler(address(docToken), ROUTE_V2), address(handlerV2), "route v2 handler");
        assertTrue(address(handlerV1) != address(handlerV2), "R47 forbids one address at both routes");
    }

    /// @notice Interest on each route is bounded by that route's own deposit — the property that
    ///         makes one-handler-per-pair a usable shape rather than just a restrictive one.
    function testInterestOnOneRouteExcludesTheOtherRoutesPrincipal() external {
        vm.warp(block.timestamp + 365 days);

        uint256 interestV1 = dcaManager.getInterestAccrued(USER, address(docToken), ROUTE_V1);
        uint256 interestV2 = dcaManager.getInterestAccrued(USER, address(docToken), ROUTE_V2);

        assertGt(interestV1, 0);
        assertGt(interestV2, 0);
        // The mock accrues 5%/year, so each route's yield is a small fraction of its own deposit
        // and nowhere near the other route's principal.
        assertLt(interestV1, DEPOSIT_V1);
        assertLt(interestV2, DEPOSIT_V2);
        assertGt(interestV1, interestV2);
    }

    /// @notice Withdrawing all interest leaves both principals intact, on the route paid and the other one.
    function testWithdrawingInterestLeavesBothPrincipalsIntact() external {
        vm.warp(block.timestamp + 365 days);

        uint256 sharesV2Before = handlerV2.getUserShares(USER);
        uint256 userDocBefore = docToken.balanceOf(USER);

        address[] memory tokens = new address[](1);
        tokens[0] = address(docToken);
        uint256[] memory routes = new uint256[](1);
        routes[0] = ROUTE_V1;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routes);

        // Only route v1 paid, and it paid strictly less than its own principal.
        assertGt(docToken.balanceOf(USER), userDocBefore);
        assertLt(docToken.balanceOf(USER) - userDocBefore, DEPOSIT_V1);
        // Route v2 is untouched: its handler never saw the call.
        assertEq(handlerV2.getUserShares(USER), sharesV2Before);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 0).tokenBalance, DEPOSIT_V1);
        assertEq(dcaManager.getDcaSchedule(USER, address(docToken), 1).tokenBalance, DEPOSIT_V2);
    }
}
