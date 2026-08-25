// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
import {FeeHandler} from "src/FeeHandler.sol";
import {DcaManagerAccessControl} from "src/DcaManagerAccessControl.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PurchaseRbtcTest
 * @notice Base-level coverage for the shared single/batch purchase algorithm, independent of
 *         MoC/Uniswap cash measurement.
 */
contract PurchaseRbtcTest is Test {
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        bytes32 indexed scheduleId,
        uint256 amountSpent
    );
    event PurchaseRbtc__SuccessfulRbtcBatchPurchase(
        address indexed token, uint256 indexed totalPurchasedRbtc, uint256 indexed totalStablecoinAmountSpent
    );

    uint256 internal constant FLAT_FEE_RATE = 100; // 1%
    uint256 internal constant FEE_DIVISOR = 10_000;
    uint256 internal constant RBTC_OUT = 1 ether;

    address internal buyerA = address(0xA11CE);
    address internal buyerB = address(0xB0B);
    address internal feeCollector = address(0xFEE);
    bytes32 internal scheduleA = keccak256("schedule-a");
    bytes32 internal scheduleB = keccak256("schedule-b");

    MockStablecoin internal token;
    PurchaseRbtcHarness internal harness;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        // dcaManager = this, so tests can call onlyDcaManager entry points directly
        harness = new PurchaseRbtcHarness(address(this), address(token), feeCollector, feeSettings);
        token.mint(address(harness), 1_000_000 ether);
        harness.setRbtcOut(RBTC_OUT);
    }

    function test_singlePurchase_usesActualRetrievedWhenBelowRequest() public {
        uint256 requested = 100 ether;
        uint256 retrieved = 50 ether;
        harness.setRetrieveOverride(retrieved);

        uint256 fee = _fee(retrieved);
        uint256 net = retrieved - fee;

        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(buyerA, address(token), RBTC_OUT, scheduleA, net);

        harness.buyRbtc(buyerA, scheduleA, requested);

        assertEq(harness.lastPurchaseAmount(), net);
        assertEq(token.balanceOf(feeCollector), fee);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT);
    }

    function test_singlePurchase_transfersFeeBeforeRouteAndPassesNet() public {
        uint256 requested = 100 ether;
        uint256 fee = _fee(requested);
        uint256 net = requested - fee;

        harness.buyRbtc(buyerA, scheduleA, requested);

        assertEq(harness.purchaseCalls(), 1);
        assertEq(harness.lastPurchaseAmount(), net);
        assertEq(harness.feeCollectorBalanceOnPurchase(), fee);
        assertEq(token.balanceOf(feeCollector), fee);
    }

    function test_singlePurchase_creditsBuyerAndEmitsOnSuccess() public {
        uint256 requested = 100 ether;
        uint256 net = requested - _fee(requested);

        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(buyerA, address(token), RBTC_OUT, scheduleA, net);

        harness.buyRbtc(buyerA, scheduleA, requested);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT);
    }

    function test_singlePurchase_zeroOutputRevertsTokenSpecificError() public {
        harness.setRbtcOut(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__RbtcPurchaseFailed.selector, buyerA, address(token)
            )
        );
        harness.buyRbtc(buyerA, scheduleA, 100 ether);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
    }

    function test_batchPurchase_revertsWhenRetrievedAtFee() public {
        (address[] memory buyers, bytes32[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        harness.setRetrieveOverride(aggregatedFee);
        harness.setRevertOnPurchase(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__StablecoinRetrievedBelowFee.selector, aggregatedFee, aggregatedFee
            )
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(token.balanceOf(feeCollector), 0);
    }

    function test_batchPurchase_revertsWhenRetrievedBelowFee() public {
        (address[] memory buyers, bytes32[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 retrieved = aggregatedFee - 1;
        harness.setRetrieveOverride(retrieved);
        harness.setRevertOnPurchase(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__StablecoinRetrievedBelowFee.selector, retrieved, aggregatedFee
            )
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), 0);
        assertEq(token.balanceOf(feeCollector), 0);
    }

    function test_batchPurchase_allocatesByPlannedNetsUsingActualCash() public {
        (address[] memory buyers, bytes32[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 totalNetPlanned = net0 + net1;
        uint256 retrieved = 150 ether;
        uint256 actualSpent = retrieved - aggregatedFee;
        harness.setRetrieveOverride(retrieved);

        _expectBatchEvents(
            buyerA, buyerB, net0, net1, totalNetPlanned, actualSpent, scheduleA, scheduleB
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts);

        assertEq(harness.lastPurchaseAmount(), actualSpent);
        assertEq(harness.feeCollectorBalanceOnPurchase(), aggregatedFee);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT * net0 / totalNetPlanned);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), RBTC_OUT * net1 / totalNetPlanned);
    }

    function test_batchPurchase_repeatedBuyersAccumulateAndEmitInOrder() public {
        address[] memory buyers = new address[](2);
        buyers[0] = buyerA;
        buyers[1] = buyerA;
        bytes32[] memory scheduleIds = new bytes32[](2);
        scheduleIds[0] = scheduleA;
        scheduleIds[1] = scheduleB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;

        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 totalNetPlanned = net0 + net1;
        uint256 actualSpent = amounts[0] + amounts[1] - _fee(amounts[0]) - _fee(amounts[1]);

        _expectBatchEvents(buyerA, buyerA, net0, net1, totalNetPlanned, actualSpent, scheduleA, scheduleB);
        harness.batchBuyRbtc(buyers, scheduleIds, amounts);

        assertEq(
            harness.getAccumulatedRbtcBalance(buyerA),
            RBTC_OUT * net0 / totalNetPlanned + RBTC_OUT * net1 / totalNetPlanned
        );
    }

    function _expectBatchEvents(
        address user0,
        address user1,
        uint256 net0,
        uint256 net1,
        uint256 totalNetPlanned,
        uint256 actualSpent,
        bytes32 id0,
        bytes32 id1
    ) private {
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(
            user0, address(token), RBTC_OUT * net0 / totalNetPlanned, id0, actualSpent * net0 / totalNetPlanned
        );
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(
            user1, address(token), RBTC_OUT * net1 / totalNetPlanned, id1, actualSpent * net1 / totalNetPlanned
        );
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(address(token), RBTC_OUT, actualSpent);
    }

    function test_batchPurchase_zeroOutputRevertsBatchError() public {
        (address[] memory buyers, bytes32[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        harness.setRbtcOut(0);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__RbtcBatchPurchaseFailed.selector, address(token))
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), 0);
    }

    function _fee(uint256 amount) private pure returns (uint256) {
        return amount * FLAT_FEE_RATE / FEE_DIVISOR;
    }

    function _twoBuyerBatch()
        private
        view
        returns (address[] memory buyers, bytes32[] memory scheduleIds, uint256[] memory amounts)
    {
        buyers = new address[](2);
        buyers[0] = buyerA;
        buyers[1] = buyerB;
        scheduleIds = new bytes32[](2);
        scheduleIds[0] = scheduleA;
        scheduleIds[1] = scheduleB;
        amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;
    }
}

contract PurchaseRbtcHarness is PurchaseRbtc {
    IERC20 internal immutable i_token;
    uint256 public lastPurchaseAmount;
    uint256 public feeCollectorBalanceOnPurchase;
    uint256 public purchaseCalls;
    uint256 public rbtcOut;
    uint256 internal retrieveOverride;
    bool internal useRetrieveOverride;
    bool internal revertOnPurchase;

    constructor(
        address dcaManagerAddress,
        address tokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    ) FeeHandler(feeCollector, feeSettings) DcaManagerAccessControl(dcaManagerAddress) {
        i_token = IERC20(tokenAddress);
    }

    function setRbtcOut(uint256 amount) external {
        rbtcOut = amount;
    }

    function setRetrieveOverride(uint256 amount) external {
        retrieveOverride = amount;
        useRetrieveOverride = true;
    }

    function setRevertOnPurchase(bool shouldRevert) external {
        revertOnPurchase = shouldRevert;
    }

    function _purchaseToken() internal view override returns (IERC20) {
        return i_token;
    }

    function _purchaseRbtc(uint256 stablecoinAmount) internal override returns (uint256) {
        if (revertOnPurchase) revert("route-called");
        purchaseCalls++;
        lastPurchaseAmount = stablecoinAmount;
        feeCollectorBalanceOnPurchase = i_token.balanceOf(s_feeCollector);
        return rbtcOut;
    }

    function _retrieveStablecoin(address, uint256 amount) internal view override returns (uint256) {
        return useRetrieveOverride ? retrieveOverride : amount;
    }

    function _batchRetrieveStablecoin(address[] memory, uint256[] memory, uint256 totalStablecoinToRetrieve)
        internal
        view
        override
        returns (uint256)
    {
        return useRetrieveOverride ? retrieveOverride : totalStablecoinToRetrieve;
    }
}
