// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LayerBankDcaManagerTest} from "test/ai-generated/unit/layerbank/LayerBankDcaManagerTest.t.sol";
import {MockLayerBankAToken} from "test/mocks/MockLayerBank.sol";
import {ILendingHandler} from "src/interfaces/ILendingHandler.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IDcaManagerAccessControl} from "src/interfaces/IDcaManagerAccessControl.sol";
import {DeployIdleHandler} from "script/DeployIdleHandler.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {batchBuyOne, toBatch} from "test/utils/BatchBuyOne.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {MinOutHarness, MockFloorSwapRouter} from "test/unit/PurchaseUniswapMinOutTest.t.sol";
import {MockStablecoinWithDecimals} from "test/mocks/MockStablecoinWithDecimals.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";

contract NethermindRejectingWallet {
    function create(IDcaManager manager, IERC20 token, address handler) external {
        token.approve(handler, type(uint256).max);
        manager.createDcaSchedule(address(token), 100 ether, 25 ether, 7 days, 1);
    }

    function claim(IDcaManager manager, address token) external {
        manager.withdrawAccumulatedRbtc(token, 1);
    }
}

contract NethermindImpostorManager {
    address public immutable i_operationsAdmin;

    constructor(address admin) {
        i_operationsAdmin = admin;
    }

    function takeApprovedTokens(ITokenHandler handler, address victim, uint256 amount) external {
        handler.depositToken(victim, amount);
        handler.withdrawToken(msg.sender, amount);
    }
}

/**
 * @notice Regression tests and accepted AuditAgent boundary cases through production contract paths.
 * @dev Local mocks establish behavior, not estimates of live incidence.
 */
contract NethermindLayerBankAuditTest is LayerBankDcaManagerTest {
    function _index(uint256 index) private {
        MockLayerBankAToken(address(handler.i_aToken())).setNormalizedIncome(index, true);
    }

    function _create(uint256 deposit, uint256 purchase) private returns (uint64) {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), deposit, purchase, 7 days, 1);
        return uint64(dcaManager.getSchedulesCreatedCount());
    }

    function test_NM1_interestWithdrawalPreservesPrincipalShares() public {
        _index(1e27);
        uint64 id = _create(1000 ether, 1000 ether);
        _index(11e26);
        address[] memory tokens = new address[](1);
        uint256[] memory routes = new uint256[](1);
        tokens[0] = address(docToken);
        routes[0] = 1;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routes);
        uint256 backing = handler.getUserShares(USER) * 11e26 / 1e27;
        assertGe(backing, 1000 ether);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 1000 ether);
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, address(docToken), id, 1);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function test_NM1_principalWithdrawalPreservesPrincipalShares() public {
        _index(11e26);
        uint64 id = _create(1100 ether, 100 ether);
        assertEq(handler.getUserShares(USER), 1000 ether);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), id, 1000 ether);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 100 ether);
        assertGe(handler.getUserShares(USER) * 11e26 / 1e27, 100 ether);
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, address(docToken), id, 1);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function test_NM1_reserveIncludesOtherPausedSchedulesAndSurvivesDeletion() public {
        _index(1e27);
        uint64 first = _create(1000 ether, 1000 ether);
        uint64 second = _create(500 ether, 500 ether);
        vm.prank(USER);
        dcaManager.setSchedulePaused(address(docToken), second, true);
        _index(11e26);
        assertEq(dcaManager.getLockedPrincipal(USER, address(docToken), address(handler)), 1500 ether);
        assertEq(dcaManager.getLockedPrincipal(USER, address(docToken), address(0xBAD)), 0);
        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(docToken), first, 1000 ether);
        assertGe(handler.getUserShares(USER) * 11e26 / 1e27, 500 ether);
        assertEq(dcaManager.getLockedPrincipal(USER, address(docToken), address(handler)), 500 ether);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(docToken), first, 0);
        assertEq(dcaManager.getLockedPrincipal(USER, address(docToken), address(handler)), 500 ether);
        vm.prank(USER);
        dcaManager.setSchedulePaused(address(docToken), second, false);
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, address(docToken), second, 1);
        assertEq(dcaManager.getLockedPrincipal(USER, address(docToken), address(handler)), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function testFuzz_NM1_partialWithdrawPreservesAggregatePrincipal(uint256 index, uint256 withdrawal) public {
        _index(1e27);
        uint64 id = _create(1000 ether, 25 ether);
        _create(500 ether, 25 ether);
        index = bound(index, 1e27, 3e27);
        withdrawal = bound(withdrawal, 1, 1000 ether);
        _index(index);
        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(docToken), id, withdrawal);
        uint256 remaining = 1500 ether - withdrawal;
        assertEq(dcaManager.getLockedPrincipal(USER, address(docToken), address(handler)), remaining);
        assertGe(handler.getUserShares(USER) * index / 1e27, remaining);
        assertEq(handler.getUserShares(USER), handler.i_aToken().scaledBalanceOf(address(handler)));
    }

    function test_NM5_freshDepositAtHalfUpIndexPurchasesFullPrincipal() public {
        _index(101e25);
        uint64 id = _create(25 ether, 25 ether);
        assertEq(handler.getUserShares(USER), (uint256(25 ether) * 1e27 + uint256(101e25) / 2) / 101e25);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 25 ether);
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, address(docToken), id, 1);
        assertEq(handler.getUserShares(USER), 0);
        assertEq(handler.i_aToken().scaledBalanceOf(address(handler)), 0);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function test_NM5_flatIndexPurchasesPreservePrincipalThroughFinalTick() public {
        _index(101e25);
        uint64 id = _create(75 ether, 25 ether);
        uint256 nextPurchaseTime = block.timestamp;
        for (uint256 tick; tick < 3; ++tick) {
            vm.prank(SWAPPER);
            batchBuyOne(dcaManager, address(docToken), id, 1);
            uint256 remaining = (2 - tick) * 25 ether;
            assertEq(dcaManager.getLockedPrincipal(USER, address(docToken), address(handler)), remaining);
            assertGe(handler.getUserShares(USER) * 101e25 / 1e27, remaining);
            assertEq(handler.getUserShares(USER), handler.i_aToken().scaledBalanceOf(address(handler)));
            nextPurchaseTime += 7 days;
            vm.warp(nextPurchaseTime);
        }
        assertEq(handler.getUserShares(USER), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function test_NM5_reducedFundingDoesNotDiluteAnotherBuyerAndMinimumRollsBack() public {
        _index(1e27);
        MockLayerBankAToken aToken = MockLayerBankAToken(address(handler.i_aToken()));
        aToken.setMintOverride(25 ether, true);
        uint64 first = _create(60 ether, 60 ether);
        uint64 third = _create(40 ether, 40 ether);
        aToken.setMintOverride(0, false);
        address other = address(0xB0B);
        docToken.mint(other, 100 ether);
        vm.startPrank(other);
        docToken.approve(address(handler), type(uint256).max);
        dcaManager.createDcaSchedule(address(docToken), 100 ether, 100 ether, 7 days, 1);
        vm.stopPrank();
        uint64 second = uint64(dcaManager.getSchedulesCreatedCount());
        vm.prank(OWNER);
        handler.setFeeRateParams(0, 0, 0);
        uint64[] memory ids = new uint64[](3);
        ids[0] = first;
        ids[1] = second;
        ids[2] = third;
        IDcaManager.Batch memory batch = toBatch(ids, address(docToken), 1);
        batch.minRbtcOut = type(uint128).max;
        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, 3e15, type(uint128).max)
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(handler.getUserShares(USER), 50 ether);
        assertEq(handler.getUserShares(other), 100 ether);
        assertEq(handler.i_aToken().scaledBalanceOf(address(handler)), 150 ether);
        assertEq(dcaManager.getDcaSchedule(address(docToken), first).tokenBalance, 60 ether);
        assertEq(dcaManager.getDcaSchedule(address(docToken), second).tokenBalance, 100 ether);
        assertEq(dcaManager.getDcaSchedule(address(docToken), third).tokenBalance, 40 ether);
        assertEq(dcaManager.getDcaSchedule(address(docToken), first).cadenceAnchor, 0);
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
        assertEq(handler.getAccumulatedRbtcBalance(other), 0);
        batch.minRbtcOut = 0;
        vm.recordLogs();
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 spent;
        uint256 output;
        uint256 rows;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IPurchaseRbtc.PurchaseRbtc__SuccessfulRbtcBatchPurchase.selector) {
                (output, spent) = abi.decode(logs[i].data, (uint256, uint256));
            }
            if (logs[i].topics[0] != IPurchaseRbtc.PurchaseRbtc__RbtcBought.selector) continue;
            (, uint256 rowSpent) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(rowSpent, rows == 0 ? 30 ether : rows == 1 ? 100 ether : 20 ether);
            ++rows;
        }
        assertEq(rows, 3);
        assertEq(spent, 150 ether);
        assertEq(handler.getAccumulatedRbtcBalance(other), output * 100 / 150);
        assertApproxEqAbs(handler.getAccumulatedRbtcBalance(USER), output * 50 / 150, 1);
        assertEq(handler.getUserShares(USER), 0);
        assertEq(handler.getUserShares(other), 0);
        assertEq(handler.i_aToken().scaledBalanceOf(address(handler)), 0);
    }

    function test_NM6_repeatedBuyerFullyBackedAggregatePurchases() public {
        _index(1e27);
        uint64 first = _create(100 ether, 100 ether);
        uint64 second = _create(100 ether, 100 ether);
        _index(17e26);
        uint256 topUp = dcaManager.getAccruedInterest(USER, address(docToken), 1);
        assertEq(topUp, 140 ether - 1);
        vm.prank(USER);
        dcaManager.topUpFromInterest(address(docToken), first, topUp);
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(docToken), first, 100 ether + topUp);
        uint256 shares = handler.getUserShares(USER);
        uint256 firstDebit = ((100 ether + topUp) * 1e27 + 17e26 - 1) / 17e26;
        uint256 secondDebit = (uint256(100 ether) * 1e27 + 17e26 - 1) / 17e26;
        assertEq(firstDebit + secondDebit, shares + 1);
        uint64[] memory ids = new uint64[](2);
        ids[0] = first;
        ids[1] = second;
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(ids, address(docToken), 1));
        assertEq(handler.getUserShares(USER), 0);
        assertEq(handler.i_aToken().scaledBalanceOf(address(handler)), 0);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 0);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 1).tokenBalance, 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function test_NM6_repeatedBuyerPurchasesWithOneWeiOfNewInterest() public {
        _index(1e27);
        uint64 first = _create(100 ether, 100 ether);
        uint64 second = _create(50 ether, 25 ether);
        uint64 third = _create(50 ether, 25 ether);
        _index(15e26);
        vm.startPrank(USER);
        dcaManager.topUpFromInterest(address(docToken), second, 50 ether - 2);
        dcaManager.topUpFromInterest(address(docToken), third, 50 ether + 1);
        dcaManager.updatePurchaseAmount(address(docToken), second, 100 ether - 2);
        dcaManager.updatePurchaseAmount(address(docToken), third, 100 ether + 1);
        vm.stopPrank();
        uint256 shares = handler.getUserShares(USER);
        uint256 newIndex = 15e26 + 5_000_000;
        _index(newIndex);
        assertEq(shares * newIndex / 1e27 - shares * 15e26 / 1e27, 1);
        uint256 separateDebits = (uint256(100 ether) * 1e27 + newIndex - 1) / newIndex
            + ((uint256(100 ether) - 2) * 1e27 + newIndex - 1) / newIndex
            + ((uint256(100 ether) + 1) * 1e27 + newIndex - 1) / newIndex;
        assertEq(separateDebits, shares + 1);
        uint64[] memory ids = new uint64[](3);
        ids[0] = first;
        ids[1] = second;
        ids[2] = third;
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(ids, address(docToken), 1));
        uint256 aggregateDebit = ((uint256(300 ether) - 1) * 1e27 + newIndex - 1) / newIndex;
        assertEq(handler.getUserShares(USER), shares - aggregateDebit);
        assertEq(handler.i_aToken().scaledBalanceOf(address(handler)), shares - aggregateDebit);
        for (uint256 i; i < 3; ++i) {
            assertEq(scheduleAt(dcaManager, USER, address(docToken), i).tokenBalance, 0);
        }
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function test_NM3_rejectingContractCanCreateButCannotClaim() public {
        _index(1e27);
        NethermindRejectingWallet wallet = new NethermindRejectingWallet();
        docToken.mint(address(wallet), 100 ether);
        wallet.create(dcaManager, docToken, address(handler));
        uint64 id = scheduleIdAt(dcaManager, address(wallet), address(docToken), 0);
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, address(docToken), id, 1);
        uint256 credit = handler.getAccumulatedRbtcBalance(address(wallet));
        assertGt(credit, 0);
        vm.expectRevert(IPurchaseRbtc.PurchaseRbtc__rBtcWithdrawalFailed.selector);
        wallet.claim(dcaManager, address(docToken));
        assertEq(handler.getAccumulatedRbtcBalance(address(wallet)), credit);
    }

    function test_NM4_ownerCanAssignHandlerWithImpostorManager() public {
        NethermindImpostorManager impostor = new NethermindImpostorManager(address(operationsAdmin));
        DeployIdleHandler deployer = new DeployIdleHandler();
        address wrong = deployer.deployIdleDocHandlerMoc(
            DeployIdleHandler.DeployParams({
                dcaManager: address(impostor),
                stablecoin: address(docToken),
                mocProxy: address(mocProxy),
                feeCollector: address(0xFEE),
                initialOwner: OWNER
            })
        );
        assertEq(IDcaManagerAccessControl(wrong).i_dcaManager(), address(impostor));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        vm.prank(USER);
        operationsAdmin.assignHandler(address(docToken), 77, wrong);
        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(77, false);
        operationsAdmin.assignHandler(address(docToken), 77, wrong);
        vm.stopPrank();
        assertEq(operationsAdmin.getHandler(address(docToken), 77), wrong);
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__OnlyDcaManagerCanCall.selector);
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), 100 ether, 25 ether, 7 days, 77);
        vm.prank(USER);
        docToken.approve(wrong, 100 ether);
        uint256 before = docToken.balanceOf(address(this));
        impostor.takeApprovedTokens(ITokenHandler(wrong), USER, 100 ether);
        assertEq(docToken.balanceOf(address(this)), before + 100 ether);
    }
}

contract NethermindDepegAuditTest is Test {
    function test_NM2_oracleFloorDoesNotAccountForStablecoinPremium() public {
        MockStablecoinWithDecimals token = new MockStablecoinWithDecimals(address(this), 18);
        MockWrbtcToken wrbtc = new MockWrbtcToken();
        MockFloorSwapRouter router = new MockFloorSwapRouter(wrbtc);
        MockMocOracle oracle = new MockMocOracle();
        oracle.setPrice(100_000 ether);
        vm.deal(address(router), 1 ether);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        IPurchaseUniswap.UniswapSettings memory settings = IPurchaseUniswap.UniswapSettings({
            wrbtc: IWRBTC(address(wrbtc)),
            swapRouter: IUniswapV3SwapRouter(address(router)),
            swapIntermediateTokens: new address[](0),
            swapPoolFeeRates: fees,
            mocOracle: ICoinPairPrice(address(oracle))
        });
        MinOutHarness harness = new MinOutHarness(
            token,
            IPurchaseFees.FeeSettings({minFeeRate: 0, maxFeeRate: 0, feePurchaseLowerBound: 250 ether}),
            settings,
            95e16,
            95e16
        );
        uint256 bound = harness.getAmountOutMinimum(100 ether);
        assertEq(bound, 95e13);
        uint256 premiumAdjustedBound = bound * 120 / 100;
        assertLt(bound, premiumAdjustedBound);
        harness.mintStablecoin(100 ether);
        router.setAmountOut(bound);
        assertEq(harness.purchaseRbtc(100 ether, 0), bound);
        harness.mintStablecoin(100 ether);
        vm.expectRevert(bytes("Too little received"));
        harness.purchaseRbtc(100 ether, premiumAdjustedBound);
    }
}
