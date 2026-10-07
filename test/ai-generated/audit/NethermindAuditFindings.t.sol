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
import {Test} from "forge-std/Test.sol";
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
 * @notice Reproduces accepted AuditAgent boundary cases through production manager and handler paths.
 * @dev These are local mock proofs of the dispositions, not fixes or estimates of live incidence.
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

    function _expectShortfall(uint64 id, uint256 amount) private {
        uint256 index = handler.i_pool().getReserveNormalizedIncome(address(docToken));
        uint256 requested = (amount * 1e27 + index - 1) / index;
        uint256 available = handler.getUserShares(USER);
        assertGt(requested, available);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingHandler.LendingHandler__InsufficientShares.selector, USER, requested, available
            )
        );
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, address(docToken), id, 1);
        assertEq(handler.getUserShares(USER), available);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, amount);
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
    }

    function _exit(uint64 id) private {
        uint256 before = docToken.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), id, type(uint256).max);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 0);
        assertEq(handler.getUserShares(USER), 0);
        assertGt(docToken.balanceOf(USER), before);
    }

    function test_NM1_interestWithdrawalLeavesOneWeiPrincipalGap() public {
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
        assertEq(backing, 1000 ether - 1);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 1000 ether);
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();
        _expectShortfall(id, 1000 ether);
        // Exit is blocked only until the protected window expires.
        vm.roll(block.number + 5);
        _exit(id);
    }

    function test_NM1_principalWithdrawalLeavesOneWeiPrincipalGap() public {
        _index(11e26);
        uint64 id = _create(1100 ether, 100 ether);
        assertEq(handler.getUserShares(USER), 1000 ether);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), id, 1000 ether);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 100 ether);
        assertEq(handler.getUserShares(USER) * 11e26 / 1e27, 100 ether - 1);
        _expectShortfall(id, 100 ether);
        _exit(id);
    }

    function test_NM5_freshDepositAtHalfUpIndexCannotPurchaseFullPrincipal() public {
        _index(101e25);
        uint64 id = _create(25 ether, 25 ether);
        assertEq(handler.getUserShares(USER), (uint256(25 ether) * 1e27 + uint256(101e25) / 2) / 101e25);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 25 ether);
        _expectShortfall(id, 25 ether);
        _exit(id);
    }

    function test_NM6_repeatedBuyerFullyBackedAggregateReverts() public {
        _index(1e27);
        uint64 first = _create(100 ether, 100 ether);
        uint64 second = _create(100 ether, 100 ether);
        _index(15e26);
        vm.prank(USER);
        dcaManager.topUpFromInterest(address(docToken), first, 100 ether);
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(docToken), first, 200 ether);
        uint256 shares = handler.getUserShares(USER);
        assertEq(shares, 200 ether);
        assertEq(shares * 15e26 / 1e27, 300 ether);
        uint256 firstDebit = (uint256(200 ether) * 1e27 + 15e26 - 1) / 15e26;
        uint256 secondDebit = (uint256(100 ether) * 1e27 + 15e26 - 1) / 15e26;
        assertEq(firstDebit + secondDebit, shares + 1);
        uint64[] memory ids = new uint64[](2);
        ids[0] = first;
        ids[1] = second;
        IDcaManager.Batch memory batch = toBatch(ids, address(docToken), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingHandler.LendingHandler__InsufficientShares.selector, USER, secondDebit, shares - firstDebit
            )
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(handler.getUserShares(USER), shares);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 0).tokenBalance, 200 ether);
        assertEq(scheduleAt(dcaManager, USER, address(docToken), 1).tokenBalance, 100 ether);
    }

    function test_NM6_oneUnderlyingWeiOfNewInterestCanStillBeInsufficient() public {
        MockLayerBankAToken token = MockLayerBankAToken(address(handler.i_aToken()));
        token.setNormalizedIncome(1e27, true);
        uint64 first = _create(100 ether, 100 ether);
        uint64 second = _create(50 ether, 50 ether);
        uint64 third = _create(50 ether, 50 ether);
        token.setNormalizedIncome(15e26, true);
        vm.startPrank(USER);
        dcaManager.topUpFromInterest(address(docToken), second, 50 ether);
        dcaManager.topUpFromInterest(address(docToken), third, 50 ether);
        dcaManager.updatePurchaseAmount(address(docToken), second, 100 ether);
        dcaManager.updatePurchaseAmount(address(docToken), third, 100 ether);
        vm.stopPrank();
        uint256 shares = handler.getUserShares(USER);
        assertEq(shares, 200 ether);
        uint256 originalIndex = 15e26;
        uint256 newIndex = originalIndex + 5_000_000;
        token.setNormalizedIncome(newIndex, true);
        assertEq(shares * newIndex / 1e27 - shares * originalIndex / 1e27, 1);
        uint256 perRow = (uint256(100 ether) * 1e27 + newIndex - 1) / newIndex;
        assertEq(3 * perRow, shares + 1);
        uint64[] memory ids = new uint64[](3);
        ids[0] = first;
        ids[1] = second;
        ids[2] = third;
        IDcaManager.Batch memory batch = toBatch(ids, address(docToken), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingHandler.LendingHandler__InsufficientShares.selector, USER, perRow, shares - 2 * perRow
            )
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(handler.getUserShares(USER), shares);
        for (uint256 i; i < 3; ++i) {
            assertEq(scheduleAt(dcaManager, USER, address(docToken), i).tokenBalance, 100 ether);
        }
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
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
