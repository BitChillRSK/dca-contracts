// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import "../Constants.sol";

/**
 * @notice Every successful Uniswap purchase must spend the whole requested stablecoin and leave the shared
 *         router's intermediate-token balances where it found them. `setUp` skips MoC lanes, which have no
 *         router, and the partial-fill cases skip forks, where the router is Uniswap's own.
 */
contract PurchaseUniswapExactConsumptionTest is DcaDappTest {
    /// @dev 1% of the requested input left unswapped. Small enough that the output still clears the 97%
    /// oracle floor, which is the whole point: `amountOutMinimum` is not evidence of full consumption.
    uint256 internal constant SHORT_FILL_PERCENT = 0.99 ether;
    uint256 internal constant FULL_FILL_PERCENT = 1 ether;
    uint256 internal constant ROUTER_DUST = 7 ether;

    /// @dev What a reverted purchase must leave untouched.
    struct PurchaseState {
        uint256 scheduleBalance;
        uint256 lastPurchaseTimestamp;
        uint256 handlerStablecoin;
        uint256 routerStablecoin;
        uint256 feeCollectorStablecoin;
        uint256 handlerWrBtc;
        uint256 userAccumulatedRbtc;
    }

    MockStablecoin internal intermediateToken;

    function setUp() public override {
        if (!isDexSwaps) vm.skip(true);
        super.setUp();
        intermediateToken = new MockStablecoin(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                              COMPLETE FILLS
    //////////////////////////////////////////////////////////////*/

    function testConfiguredPathSpendsExactlyTheRequestedStablecoin() public {
        _assertFullFillSpendsEverything();
    }

    function testDirectPathSpendsExactlyTheRequestedStablecoin() public {
        _skipWhereThePathIsNotOurs();
        _activateDirectPath();
        _assertFullFillSpendsEverything();
    }

    function testOneIntermediateFillLeavesTheRouterBalanceUnchanged() public {
        _skipWhereThePathIsNotOurs();
        _activateOneHopPath(address(intermediateToken));
        uint256 routerBefore = intermediateToken.balanceOf(_routerAddress());
        _assertFullFillSpendsEverything();
        assertEq(intermediateToken.balanceOf(_routerAddress()), routerBefore);
    }

    function testPreexistingRouterDustDoesNotBlockAPurchase() public {
        _skipWhereThePathIsNotOurs();
        _activateOneHopPath(address(intermediateToken));
        intermediateToken.mint(_routerAddress(), ROUTER_DUST);

        _assertFullFillSpendsEverything();
        // Unsolicited tokens sitting on a public router are compared against themselves, not against zero.
        assertEq(intermediateToken.balanceOf(_routerAddress()), ROUTER_DUST);
    }

    /*//////////////////////////////////////////////////////////////
                              PARTIAL FILLS
    //////////////////////////////////////////////////////////////*/

    function testDirectPartialFillRevertsEvenWhenItClearsMinOut() public {
        _skipOnFork();
        _activateDirectPath();
        _shortFillTheInput();

        PurchaseState memory before = _snapshot();
        uint64 scheduleId = _scheduleId();
        _expectShortFillRevert();
        _purchase(scheduleId);
        _assertRolledBack(before);
    }

    function testFirstHopPartialFillOnAMultihopPathReverts() public {
        _skipOnFork();
        _activateOneHopPath(address(intermediateToken));
        _shortFillTheInput();

        PurchaseState memory before = _snapshot();
        uint64 scheduleId = _scheduleId();
        _expectShortFillRevert();
        _purchase(scheduleId);
        _assertRolledBack(before);
        assertEq(intermediateToken.balanceOf(_routerAddress()), 0);
    }

    function testLaterHopPartialFillStrandsNothingBecauseItReverts() public {
        _skipOnFork();
        _activateOneHopPath(address(intermediateToken));
        // The whole input leaves the handler, so only the router's intermediate balance can show that a
        // later hop stopped short.
        uint256 stranded = (_netAmountToSpend() * (FULL_FILL_PERCENT - SHORT_FILL_PERCENT)) / FULL_FILL_PERCENT;
        _router().setOutputFillPercent(SHORT_FILL_PERCENT);
        _router().setStrandedIntermediate(address(intermediateToken), stranded);

        PurchaseState memory before = _snapshot();
        uint64 scheduleId = _scheduleId();
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__IntermediateBalanceChangedInRouter.selector,
                address(intermediateToken),
                0,
                stranded
            )
        );
        _purchase(scheduleId);
        _assertRolledBack(before);
        assertEq(intermediateToken.balanceOf(_routerAddress()), 0);
    }

    function testLaterHopPartialFillIsCaughtOnTopOfRouterDust() public {
        _skipOnFork();
        _activateOneHopPath(address(intermediateToken));
        intermediateToken.mint(_routerAddress(), ROUTER_DUST);
        uint256 stranded = (_netAmountToSpend() * (FULL_FILL_PERCENT - SHORT_FILL_PERCENT)) / FULL_FILL_PERCENT;
        _router().setOutputFillPercent(SHORT_FILL_PERCENT);
        _router().setStrandedIntermediate(address(intermediateToken), stranded);

        PurchaseState memory before = _snapshot();
        uint64 scheduleId = _scheduleId();
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__IntermediateBalanceChangedInRouter.selector,
                address(intermediateToken),
                ROUTER_DUST,
                ROUTER_DUST + stranded
            )
        );
        _purchase(scheduleId);
        _assertRolledBack(before);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A complete fill debits the schedule and pays the fee, and credits the buyer exactly the WRBTC
    ///      the handler measured itself receiving. Lending handlers hold no stablecoin between redemptions,
    ///      so their handler balance is unchanged across a successful purchase. Idle handlers hold the pool
    ///      on the contract, so the same purchase drops the handler balance by the full gross spend.
    function _assertFullFillSpendsEverything() private {
        PurchaseState memory before = _snapshot();

        _purchase(_scheduleId());

        PurchaseState memory afterPurchase = _snapshot();
        if (isNone) {
            assertEq(before.handlerStablecoin - afterPurchase.handlerStablecoin, AMOUNT_TO_SPEND);
        } else {
            assertEq(afterPurchase.handlerStablecoin, before.handlerStablecoin);
        }
        assertEq(before.scheduleBalance - afterPurchase.scheduleBalance, AMOUNT_TO_SPEND);
        assertEq(afterPurchase.feeCollectorStablecoin - before.feeCollectorStablecoin, _fee());
        assertEq(
            afterPurchase.userAccumulatedRbtc - before.userAccumulatedRbtc,
            afterPurchase.handlerWrBtc - before.handlerWrBtc
        );
        assertGt(afterPurchase.userAccumulatedRbtc, before.userAccumulatedRbtc);

        // Naming the amount that moved is a mock-router assertion: `MockSwapRouter02` keeps what it pulls,
        // while Uniswap's own SwapRouter02 forwards the input straight into the pool and ends holding none
        // of it. On a fork the handler-side delta above is the venue-independent half.
        if (block.chainid == ANVIL_CHAIN_ID) {
            assertEq(afterPurchase.routerStablecoin - before.routerStablecoin, _netAmountToSpend());
        }
    }

    function _assertRolledBack(PurchaseState memory before) private {
        PurchaseState memory afterRevert = _snapshot();
        assertEq(afterRevert.scheduleBalance, before.scheduleBalance);
        assertEq(afterRevert.lastPurchaseTimestamp, before.lastPurchaseTimestamp);
        assertEq(afterRevert.handlerStablecoin, before.handlerStablecoin);
        assertEq(afterRevert.routerStablecoin, before.routerStablecoin);
        assertEq(afterRevert.feeCollectorStablecoin, before.feeCollectorStablecoin);
        assertEq(afterRevert.handlerWrBtc, before.handlerWrBtc);
        assertEq(afterRevert.userAccumulatedRbtc, before.userAccumulatedRbtc);
    }

    function _snapshot() private view returns (PurchaseState memory state) {
        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        state.scheduleBalance = schedule.tokenBalance;
        state.lastPurchaseTimestamp = schedule.lastPurchaseTimestamp;
        state.handlerStablecoin = stablecoin.balanceOf(address(stablecoinHandler));
        state.routerStablecoin = stablecoin.balanceOf(_routerAddress());
        state.feeCollectorStablecoin = stablecoin.balanceOf(FEE_COLLECTOR);
        state.handlerWrBtc = wrBtcToken.balanceOf(address(stablecoinHandler));
        state.userAccumulatedRbtc = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
    }

    /// @dev Takes the id rather than reading it, so a caller's `vm.expectRevert` lands on the batch call
    ///      itself and not on the getter that would otherwise run first.
    function _purchase(uint64 scheduleId) private {
        buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);
    }

    function _scheduleId() private view returns (uint64) {
        return dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
    }

    /// @dev The handler pays the fee first, then snapshots its stablecoin balance for the consumption
    ///      check. Lending retrieval leaves only the net swap amount on the handler; idle funds were
    ///      already there, so the before-balance is the pool minus the fee just paid.
    function _expectShortFillRevert() private {
        uint256 netAmount = _netAmountToSpend();
        uint256 inputBalanceBefore = isNone
            ? stablecoin.balanceOf(address(stablecoinHandler)) - _fee()
            : netAmount;
        uint256 unspent = netAmount - (netAmount * SHORT_FILL_PERCENT) / FULL_FILL_PERCENT;
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__InputAmountNotFullySpent.selector,
                netAmount,
                inputBalanceBefore,
                inputBalanceBefore - (netAmount - unspent)
            )
        );
    }

    function _shortFillTheInput() private {
        // The pools take less than asked and pay for only what they took, so the swap still clears min-out.
        _router().setInputConsumedPercent(SHORT_FILL_PERCENT);
        _router().setOutputFillPercent(SHORT_FILL_PERCENT);
    }

    function _fee() private view returns (uint256) {
        return feeCalculator.calculateFee(AMOUNT_TO_SPEND);
    }

    function _netAmountToSpend() private view returns (uint256) {
        return AMOUNT_TO_SPEND - _fee();
    }

    function _activateDirectPath() private {
        address[] memory mids = new address[](0);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        _activatePath(mids, fees);
    }

    function _activateOneHopPath(address mid) private {
        address[] memory mids = new address[](1);
        mids[0] = mid;
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;
        _activatePath(mids, fees);
    }

    function _activatePath(address[] memory mids, uint24[] memory fees) private {
        IPurchaseUniswap handler = IPurchaseUniswap(address(stablecoinHandler));
        bytes32 pathHash = keccak256(_encodePath(mids, fees));
        if (!handler.isPurchasePathAllowed(pathHash)) {
            vm.prank(OWNER);
            handler.setPurchasePathAllowed(mids, fees, true);
        }
        vm.prank(OWNER);
        handler.setPurchasePath(mids, fees);
    }

    function _encodePath(address[] memory mids, uint24[] memory fees) private view returns (bytes memory path) {
        path = abi.encodePacked(address(stablecoin));
        for (uint256 i; i < mids.length; ++i) {
            path = abi.encodePacked(path, fees[i], mids[i]);
        }
        path = abi.encodePacked(path, fees[fees.length - 1], address(wrBtcToken));
    }

    function _routerAddress() private view returns (address) {
        return dexHelperConfig.getActiveNetworkConfig().swapRouter02Address;
    }

    function _router() private view returns (MockSwapRouter02) {
        return MockSwapRouter02(_routerAddress());
    }

    /// @dev A manufactured partial fill needs the mock router. On a fork the router is Uniswap's own and
    ///      the pools decide; the deterministic cases are the point of this file.
    function _skipOnFork() private {
        if (block.chainid != ANVIL_CHAIN_ID) vm.skip(true);
    }

    /// @dev These cases activate a route this test invented — a direct pair, or a hop through a token this
    ///      file just deployed. Locally the mock router fills anything; on a fork there is no such pool, so
    ///      the swap would revert on liquidity and prove nothing about the checks under test. The configured
    ///      path is what the fork lane exercises.
    function _skipWhereThePathIsNotOurs() private {
        if (block.chainid != ANVIL_CHAIN_ID) vm.skip(true);
    }
}
