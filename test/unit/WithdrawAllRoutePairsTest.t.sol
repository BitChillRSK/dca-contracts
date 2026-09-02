// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./deployment/BaseDeploymentTest.t.sol";
import {DeployLayerBankHandler} from "../../script/DeployLayerBankHandler.s.sol";
import {LayerBankDocHandlerMoc} from "../../src/layerbank/LayerBankDocHandlerMoc.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IOperationsAdmin} from "../../src/interfaces/IOperationsAdmin.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {ITokenLending} from "../../src/interfaces/ITokenLending.sol";
import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import "../Constants.sol";

/**
 * @title WithdrawAllRoutePairsTest
 * @notice `withdrawAllAccumulatedInterest` and `withdrawAllAccumulatedRbtc` take positional
 *         `(token, routeIndex)` pairs, so a caller reaches exactly the routes it names.
 * @dev The mixed case is the one the old cartesian form could not express: a user holding
 *      `(tokenOne, routeOne)` and `(tokenTwo, routeTwo)` had to send both tokens and both
 *      indexes, which also resolved and called the handler on `(tokenOne, routeTwo)`. That
 *      third pair is deliberately assigned a real handler here — an unassigned one would be
 *      skipped on the zero-address check and prove nothing. The assertions are call counts on
 *      that handler, not the user's resulting balance, which is equal either way.
 *
 *      Anvil and DOC only, like `VersionedRouteAccountingTest`: it mints its own second
 *      stablecoin and relies on the LayerBank Pool/aToken mocks to accrue yield, neither of
 *      which exists on a fork.
 */
contract WithdrawAllRoutePairsTest is BaseDeploymentTest {
    uint256 internal constant ROUTE_ONE = 31;
    uint256 internal constant ROUTE_TWO = 32;
    uint256 internal constant DEPOSIT = 400 ether;

    address internal constant USER = address(0x7777);

    MockStablecoin internal tokenOne;
    MockStablecoin internal tokenTwo;

    // (tokenOne, ROUTE_ONE) and (tokenTwo, ROUTE_TWO) hold the user's positions.
    LayerBankDocHandlerMoc internal handlerOneOne;
    LayerBankDocHandlerMoc internal handlerTwoTwo;
    // (tokenOne, ROUTE_TWO) is registered but unused: the combination the cartesian form forced.
    LayerBankDocHandlerMoc internal handlerOneTwo;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DOC_STRING);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        super.setUp();

        tokenOne = MockStablecoin(helperConfig.getStablecoinAddress());
        tokenTwo = new MockStablecoin(OWNER);
        address mocProxyAddress = helperConfig.getActiveNetworkConfig().mocProxyAddress;

        DeployLayerBankHandler deployer = new DeployLayerBankHandler();
        handlerOneOne = _deployHandler(deployer, address(tokenOne), mocProxyAddress);
        handlerTwoTwo = _deployHandler(deployer, address(tokenTwo), mocProxyAddress);
        handlerOneTwo = _deployHandler(deployer, address(tokenOne), mocProxyAddress);

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(ROUTE_ONE, true);
        operationsAdmin.registerRoute(ROUTE_TWO, true);
        operationsAdmin.assignTokenHandler(address(tokenOne), ROUTE_ONE, address(handlerOneOne));
        operationsAdmin.assignTokenHandler(address(tokenTwo), ROUTE_TWO, address(handlerTwoTwo));
        operationsAdmin.assignTokenHandler(address(tokenOne), ROUTE_TWO, address(handlerOneTwo));
        vm.stopPrank();
        // (tokenTwo, ROUTE_ONE) stays unassigned: the fourth cell of the grid.

        tokenOne.mint(USER, DEPOSIT);
        tokenTwo.mint(USER, DEPOSIT);
        vm.startPrank(USER);
        tokenOne.approve(address(handlerOneOne), type(uint256).max);
        tokenTwo.approve(address(handlerTwoTwo), type(uint256).max);
        dcaManager.createDcaSchedule(address(tokenOne), DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, ROUTE_ONE);
        dcaManager.createDcaSchedule(address(tokenTwo), DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, ROUTE_TWO);
        vm.stopPrank();
    }

    function _deployHandler(DeployLayerBankHandler deployer, address token, address mocProxy)
        private
        returns (LayerBankDocHandlerMoc)
    {
        return LayerBankDocHandlerMoc(
            payable(
                deployer.deployMocksAndHandler(
                    address(dcaManager), token, mocProxy, makeAddr(FEE_COLLECTOR_STRING), OWNER
                )
            )
        );
    }

    function _mixedPairs() private view returns (address[] memory tokens, uint256[] memory routeIndexes) {
        tokens = new address[](2);
        tokens[0] = address(tokenOne);
        tokens[1] = address(tokenTwo);
        routeIndexes = new uint256[](2);
        routeIndexes[0] = ROUTE_ONE;
        routeIndexes[1] = ROUTE_TWO;
    }

    /// @notice The mixed case reaches both held routes and never touches the cross combination.
    function testWithdrawAllInterestOnlyCallsTheNamedPairs() external {
        vm.warp(block.timestamp + 365 days);

        uint256 interestOne = dcaManager.getInterestAccrued(USER, address(tokenOne), ROUTE_ONE);
        uint256 interestTwo = dcaManager.getInterestAccrued(USER, address(tokenTwo), ROUTE_TWO);
        assertGt(interestOne, 0);
        assertGt(interestTwo, 0);

        uint256 balanceOneBefore = tokenOne.balanceOf(USER);
        uint256 balanceTwoBefore = tokenTwo.balanceOf(USER);

        (address[] memory tokens, uint256[] memory routeIndexes) = _mixedPairs();

        // The cross pair is never resolved and its handler is never called.
        vm.expectCall(
            address(operationsAdmin),
            abi.encodeCall(IOperationsAdmin.getTokenHandler, (address(tokenOne), ROUTE_TWO)),
            0
        );
        vm.expectCall(address(handlerOneTwo), abi.encodeWithSelector(ITokenLending.withdrawInterest.selector), 0);
        // One lending-class lookup per pair, not one per combination: the cartesian form made four.
        vm.expectCall(address(operationsAdmin), abi.encodeCall(IOperationsAdmin.isLendingRoute, (ROUTE_ONE)), 1);
        vm.expectCall(address(operationsAdmin), abi.encodeCall(IOperationsAdmin.isLendingRoute, (ROUTE_TWO)), 1);

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        // Both named routes paid, and the principal on each stayed put.
        assertApproxEqRel(tokenOne.balanceOf(USER) - balanceOneBefore, interestOne, 1);
        assertApproxEqRel(tokenTwo.balanceOf(USER) - balanceTwoBefore, interestTwo, 1);
        assertEq(handlerOneTwo.getUserShares(USER), 0, "cross-pair handler holds no position");
        assertEq(dcaManager.getDcaSchedule(USER, address(tokenOne), 0).tokenBalance, DEPOSIT);
        assertEq(dcaManager.getDcaSchedule(USER, address(tokenTwo), 0).tokenBalance, DEPOSIT);
    }

    /// @notice The rBTC path zips the same way.
    /// @dev No purchase is needed: the balance read is itself a handler call, so its count proves
    ///      which handlers the loop reached.
    function testWithdrawAllRbtcOnlyCallsTheNamedPairs() external {
        (address[] memory tokens, uint256[] memory routeIndexes) = _mixedPairs();

        bytes memory balanceCall = abi.encodeCall(IPurchaseRbtc.getAccumulatedRbtcBalance, (USER));
        vm.expectCall(address(handlerOneOne), balanceCall, 1);
        vm.expectCall(address(handlerTwoTwo), balanceCall, 1);
        vm.expectCall(address(handlerOneTwo), balanceCall, 0);
        vm.expectCall(
            address(operationsAdmin),
            abi.encodeCall(IOperationsAdmin.getTokenHandler, (address(tokenOne), ROUTE_TWO)),
            0
        );

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
    }

    /// @notice A single pair withdraws that route only; the other route on the same token is untouched.
    function testWithdrawAllInterestOnOnePairLeavesTheOtherRoutesAlone() external {
        vm.warp(block.timestamp + 365 days);

        uint256 interestOne = dcaManager.getInterestAccrued(USER, address(tokenOne), ROUTE_ONE);
        uint256 balanceOneBefore = tokenOne.balanceOf(USER);
        uint256 balanceTwoBefore = tokenTwo.balanceOf(USER);

        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenOne);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = ROUTE_ONE;

        vm.expectCall(address(handlerOneTwo), abi.encodeWithSelector(ITokenLending.withdrawInterest.selector), 0);
        vm.expectCall(address(handlerTwoTwo), abi.encodeWithSelector(ITokenLending.withdrawInterest.selector), 0);

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        assertApproxEqRel(tokenOne.balanceOf(USER) - balanceOneBefore, interestOne, 1);
        assertEq(tokenTwo.balanceOf(USER), balanceTwoBefore, "the unnamed route paid out");
    }

    /// @notice An unassigned pair in the middle of a valid list is skipped, not reverted.
    function testWithdrawAllInterestSkipsTheUnassignedCellOfTheGrid() external {
        vm.warp(block.timestamp + 365 days);

        uint256 interestTwo = dcaManager.getInterestAccrued(USER, address(tokenTwo), ROUTE_TWO);
        uint256 balanceTwoBefore = tokenTwo.balanceOf(USER);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenTwo); // (tokenTwo, ROUTE_ONE) has no handler
        tokens[1] = address(tokenTwo);
        uint256[] memory routeIndexes = new uint256[](2);
        routeIndexes[0] = ROUTE_ONE;
        routeIndexes[1] = ROUTE_TWO;

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        assertApproxEqRel(tokenTwo.balanceOf(USER) - balanceTwoBefore, interestTwo, 1);
    }

    /// @notice Mismatched lengths revert on both entry points.
    function testWithdrawAllRevertsOnLengthMismatch() external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenOne);
        tokens[1] = address(tokenTwo);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = ROUTE_ONE;

        vm.startPrank(USER);
        vm.expectRevert(IDcaManager.DcaManager__ArraysLengthMismatch.selector);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
        vm.expectRevert(IDcaManager.DcaManager__ArraysLengthMismatch.selector);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
        vm.stopPrank();
    }

    /// @notice Empty input reverts on both entry points instead of succeeding silently.
    function testWithdrawAllRevertsOnEmptyArrays() external {
        address[] memory tokens = new address[](0);
        uint256[] memory routeIndexes = new uint256[](0);

        vm.startPrank(USER);
        vm.expectRevert(IDcaManager.DcaManager__EmptyWithdrawalArrays.selector);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
        vm.expectRevert(IDcaManager.DcaManager__EmptyWithdrawalArrays.selector);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
        vm.stopPrank();
    }
}
