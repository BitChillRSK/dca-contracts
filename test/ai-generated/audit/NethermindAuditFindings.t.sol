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
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = 1;
        manager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
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
    address internal constant OTHER = address(0xB0B);

    function _index(uint256 index) private {
        MockLayerBankAToken(address(handler.i_aToken())).setNormalizedIncome(index, true);
    }

    function _create(uint256 deposit, uint256 purchase) private returns (uint64) {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), deposit, purchase, 7 days, 1);
        return uint64(dcaManager.getSchedulesCreatedCount());
    }

    function _balanceAt(uint256 position) private view returns (uint256) {
        return scheduleAt(dcaManager, USER, address(docToken), position).tokenBalance;
    }

    /// @dev Every virtual share on the books is a receipt share the handler holds, and no more.
    function _assertBooksEqualExternal() private {
        assertEq(
            handler.getUserShares(USER) + handler.getUserShares(OTHER),
            handler.i_aToken().scaledBalanceOf(address(handler)),
            "virtual shares != external receipt shares"
        );
    }

    function _buy(uint64[] memory ids) private {
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(ids, address(docToken), 1));
    }

    function _ids(uint64 a) private pure returns (uint64[] memory ids) {
        ids = new uint64[](1);
        ids[0] = a;
    }

    function _ids(uint64 a, uint64 b) private pure returns (uint64[] memory ids) {
        ids = new uint64[](2);
        ids[0] = a;
        ids[1] = b;
    }

    /*//////////////////////////////////////////////////////////////
        FINDING 1 - withdrawals round the share debit up
    //////////////////////////////////////////////////////////////*/

    /// @dev Report: "LayerBank interest-only exact-burn example". 1.1 RAY, interest claimed, then the final buy.
    function test_NM1_interestWithdrawalThenFinalPurchase() public {
        _index(1e27);
        uint64 id = _create(1000 ether, 1000 ether);
        _index(11e26);
        address[] memory tokens = new address[](1);
        uint256[] memory routes = new uint256[](1);
        tokens[0] = address(docToken);
        routes[0] = 1;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routes);
        assertEq(_balanceAt(0), 1000 ether);

        _buy(_ids(id));

        assertEq(_balanceAt(0), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
        _assertBooksEqualExternal();
    }

    /// @dev Report: "LayerBank principal exact-burn example". Withdraw 10/11 of the deposit, then the final buy.
    function test_NM1_principalWithdrawalThenFinalPurchase() public {
        _index(11e26);
        uint64 id = _create(1100 ether, 100 ether);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), id, 1000 ether);
        assertEq(_balanceAt(0), 100 ether);

        _buy(_ids(id));

        assertEq(_balanceAt(0), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
        _assertBooksEqualExternal();
    }

    /// @dev Report: "Combined principal and interest withdrawal", with a second paused schedule sharing the shares.
    function test_NM1_combinedWithdrawalThenOtherSchedulePurchases() public {
        _index(1e27);
        uint64 first = _create(1000 ether, 1000 ether);
        uint64 second = _create(500 ether, 500 ether);
        vm.prank(USER);
        dcaManager.setSchedulePaused(address(docToken), second, true);
        _index(11e26);
        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(docToken), first, 1000 ether);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(docToken), first, 0);
        vm.prank(USER);
        dcaManager.setSchedulePaused(address(docToken), second, false);

        _buy(_ids(second));

        assertEq(_balanceAt(0), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
        _assertBooksEqualExternal();
    }

    /// @dev Any index, any partial withdrawal: the purchase that spends every remaining unit still executes.
    function testFuzz_NM1_withdrawalNeverBlocksThePurchaseOfTheRemainder(uint256 index, uint256 withdrawal) public {
        _index(1e27);
        uint64 first = _create(1000 ether, 25 ether);
        uint64 second = _create(500 ether, 25 ether);
        index = bound(index, 1e27, 3e27);
        withdrawal = bound(withdrawal, 1, 975 ether);
        _index(index);
        vm.startPrank(USER);
        dcaManager.withdrawTokenAndInterest(address(docToken), first, withdrawal);
        dcaManager.updatePurchaseAmount(address(docToken), first, 1000 ether - withdrawal);
        dcaManager.updatePurchaseAmount(address(docToken), second, 500 ether);
        vm.stopPrank();

        _buy(_ids(first, second));

        assertEq(_balanceAt(0), 0);
        assertEq(_balanceAt(1), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
        _assertBooksEqualExternal();
    }

    /*//////////////////////////////////////////////////////////////
        FINDING 5 - the mint rounds below the nominal deposit
    //////////////////////////////////////////////////////////////*/

    /// @dev Report: 1.01 RAY, deposit equals purchase amount, bought at the same index.
    function test_NM5_freshDepositThenFullPurchase() public {
        _index(101e25);
        uint64 id = _create(25 ether, 25 ether);
        assertEq(handler.getUserShares(USER), (uint256(25 ether) * 1e27 + uint256(101e25) / 2) / 101e25);

        _buy(_ids(id));

        assertEq(handler.getUserShares(USER), 0);
        assertEq(_balanceAt(0), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
        _assertBooksEqualExternal();
    }

    /// @dev A market that never accrues: three ticks at one index, through the last one.
    function test_NM5_flatIndexThroughTheFinalTick() public {
        _index(101e25);
        uint64 id = _create(75 ether, 25 ether);
        uint256 nextPurchaseTime = block.timestamp;
        for (uint256 tick; tick < 3; ++tick) {
            _buy(_ids(id));
            assertEq(_balanceAt(0), (2 - tick) * 25 ether);
            _assertBooksEqualExternal();
            nextPurchaseTime += 7 days;
            vm.warp(nextPurchaseTime);
        }
        assertEq(handler.getUserShares(USER), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    /// @dev A row far short of its nominal amount must not be paid for by the healthy buyer beside it,
    ///      and a batch that then misses the caller's minimum must leave nothing behind.
    function test_NM5_shortRowIsNotPaidForByTheHealthyBuyerAndAMissedMinimumRollsBack() public {
        _index(1e27);
        MockLayerBankAToken aToken = MockLayerBankAToken(address(handler.i_aToken()));
        aToken.setMintOverride(50 ether, true);
        uint64 short = _create(100 ether, 100 ether); // 50 shares against 100 nominal
        aToken.setMintOverride(0, false);
        docToken.mint(OTHER, 100 ether);
        vm.startPrank(OTHER);
        docToken.approve(address(handler), type(uint256).max);
        dcaManager.createDcaSchedule(address(docToken), 100 ether, 100 ether, 7 days, 1);
        vm.stopPrank();
        uint64 healthy = uint64(dcaManager.getSchedulesCreatedCount());
        vm.prank(OWNER);
        handler.setFeeRateParams(0, 0, 0);

        IDcaManager.Batch memory batch = toBatch(_ids(short, healthy), address(docToken), 1);
        batch.minRbtcOut = type(uint128).max;
        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, 3e15, type(uint128).max)
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(handler.getUserShares(USER), 50 ether);
        assertEq(handler.getUserShares(OTHER), 100 ether);
        _assertBooksEqualExternal();
        assertEq(docToken.balanceOf(address(handler)), 0);
        assertEq(dcaManager.getDcaSchedule(address(docToken), short).tokenBalance, 100 ether);
        assertEq(dcaManager.getDcaSchedule(address(docToken), healthy).tokenBalance, 100 ether);
        assertEq(dcaManager.getDcaSchedule(address(docToken), short).cadenceAnchor, 0);
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
        assertEq(handler.getAccumulatedRbtcBalance(OTHER), 0);

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
            assertEq(rowSpent, rows == 0 ? 50 ether : 100 ether, "row spend follows funding");
            ++rows;
        }
        assertEq(rows, 2);
        assertEq(spent, 150 ether);
        assertEq(handler.getAccumulatedRbtcBalance(OTHER), output * 100 / 150, "healthy buyer keeps its full share");
        assertEq(handler.getAccumulatedRbtcBalance(USER), output * 50 / 150);
        assertEq(handler.getUserShares(USER), 0);
        assertEq(handler.getUserShares(OTHER), 0);
        _assertBooksEqualExternal();
    }

    /*//////////////////////////////////////////////////////////////
        FINDING 6 - one buyer, several rows, separate ceilings
    //////////////////////////////////////////////////////////////*/

    /// @dev Report: compound all interest into one schedule, then buy both schedules' full balances.
    function test_NM6_repeatedBuyerWhoseRowsAreExactlyBackedInAggregate() public {
        _index(1e27);
        uint64 first = _create(100 ether, 100 ether);
        uint64 second = _create(100 ether, 100 ether);
        _index(17e26);
        uint256 topUp = dcaManager.getAccruedInterest(USER, address(docToken), 1);
        vm.startPrank(USER);
        dcaManager.topUpFromInterest(address(docToken), first, topUp);
        dcaManager.updatePurchaseAmount(address(docToken), first, 100 ether + topUp);
        vm.stopPrank();
        uint256 shares = handler.getUserShares(USER);
        uint256 separateDebits =
            ((100 ether + topUp) * 1e27 + 17e26 - 1) / 17e26 + (uint256(100 ether) * 1e27 + 17e26 - 1) / 17e26;
        assertGt(separateDebits, shares, "precondition: per-row ceilings ask for more shares than the buyer holds");

        _buy(_ids(first, second));

        assertEq(_balanceAt(0), 0);
        assertEq(_balanceAt(1), 0);
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
        _assertBooksEqualExternal();
    }

    /// @dev Three rows, and one base unit of fresh interest that separate ceilings still cannot use.
    function test_NM6_threeRowsWithOneUnitOfNewInterest() public {
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
        assertGt(separateDebits, shares, "precondition: per-row ceilings ask for more shares than the buyer holds");
        uint64[] memory ids = new uint64[](3);
        ids[0] = first;
        ids[1] = second;
        ids[2] = third;

        _buy(ids);

        for (uint256 i; i < 3; ++i) {
            assertEq(_balanceAt(i), 0);
        }
        assertGt(handler.getAccumulatedRbtcBalance(USER), 0);
        _assertBooksEqualExternal();
    }

    function test_loss20Percent_nextPurchaseStillFundsFullRow() public {
        _index(2e27);
        uint64 id = _create(1000 ether, 25 ether);
        _index(16e26);
        vm.recordLogs();
        _buy(_ids(id));
        assertEq(_balanceAt(0), 975 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool bought;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IPurchaseRbtc.PurchaseRbtc__RbtcBought.selector) continue;
            (, uint256 spent) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(spent, 25 ether);
            bought = true;
        }
        assertTrue(bought);
        _assertBooksEqualExternal();
    }

    function test_loss20Percent_partialWithdrawalStillPaysFullRequest() public {
        _index(2e27);
        uint64 id = _create(1000 ether, 25 ether);
        _index(16e26);
        uint256 cashBefore = docToken.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), id, 100 ether);
        assertEq(docToken.balanceOf(USER) - cashBefore, 100 ether);
        assertEq(_balanceAt(0), 900 ether);
        _assertBooksEqualExternal();
    }

    function test_zeroShareRowRollsBackSchedulesAndVenue() public {
        _assertZeroShareRowRollback(false);
    }

    function test_repeatedBuyerEmptySecondRowRollsBackSchedulesAndVenue() public {
        _assertZeroShareRowRollback(true);
    }

    function _assertZeroShareRowRollback(bool repeated) private {
        // Normal half-up mints create 50 shares backing 100 tokens in nominal schedules.
        _index(2e27);
        uint64 first = _create(60 ether, 60 ether);
        uint64 second = _create(40 ether, 40 ether);
        assertEq(handler.getUserShares(USER), 50 ether);
        // A loss leaves 50 tokens of share value. The first row consumes the entire position.
        // This models a loss boundary, not the live LayerBank index's current monotonic behavior.
        _index(1e27);
        if (!repeated) {
            _buy(_ids(first));
            assertEq(handler.getUserShares(USER), 0);
            vm.warp(block.timestamp + 7 days);
        }
        uint64[] memory ids = repeated ? _ids(first, second) : _ids(second);
        uint256 userShares = handler.getUserShares(USER);
        uint256 externalShares = handler.i_aToken().scaledBalanceOf(address(handler));
        uint256 credit = handler.getAccumulatedRbtcBalance(USER);
        uint256 firstBalance = dcaManager.getDcaSchedule(address(docToken), first).tokenBalance;
        uint256 firstAnchor = dcaManager.getDcaSchedule(address(docToken), first).cadenceAnchor;
        uint256 secondBalance = dcaManager.getDcaSchedule(address(docToken), second).tokenBalance;
        uint256 venueCash = docToken.balanceOf(address(mocProxy));
        uint256 venueRbtc = address(mocProxy).balance;
        vm.expectRevert(
            abi.encodeWithSelector(ILendingHandler.LendingHandler__ZeroShareValue.selector, USER, 40 ether, 0)
        );
        _buy(ids);
        assertEq(handler.getUserShares(USER), userShares);
        assertEq(handler.i_aToken().scaledBalanceOf(address(handler)), externalShares);
        assertEq(handler.getAccumulatedRbtcBalance(USER), credit);
        assertEq(dcaManager.getDcaSchedule(address(docToken), first).tokenBalance, firstBalance);
        assertEq(dcaManager.getDcaSchedule(address(docToken), first).cadenceAnchor, firstAnchor);
        assertEq(dcaManager.getDcaSchedule(address(docToken), second).tokenBalance, secondBalance);
        assertEq(dcaManager.getDcaSchedule(address(docToken), second).cadenceAnchor, 0);
        assertEq(docToken.balanceOf(address(mocProxy)), venueCash);
        assertEq(address(mocProxy).balance, venueRbtc);
        assertEq(docToken.balanceOf(address(handler)), 0);
        _assertBooksEqualExternal();
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
