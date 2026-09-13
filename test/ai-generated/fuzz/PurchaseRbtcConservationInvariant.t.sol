// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {PurchaseRbtcHarness} from "test/unit/PurchaseRbtcTest.t.sol";

/**
 * @title PurchaseRbtcConservationHandler
 * @notice Fuzz actions over the real `PurchaseRbtc` batch pipeline.
 * @dev Drives `batchBuyRbtc` at random row counts, weights, and venue outputs, and withdraws for
 *      random buyers. Both actions swallow reverts so `fail_on_revert = true` reports protocol
 *      breakage rather than an unlucky draw.
 */
contract PurchaseRbtcConservationHandler is Test {
    uint256 internal constant MAX_ROWS = 12;
    /// @dev Above the fee's upper bound, so every row pays the same rate and weights stay unequal.
    uint256 internal constant MIN_AMOUNT = 1 ether;
    uint256 internal constant MAX_AMOUNT = 500_000 ether;

    PurchaseRbtcHarness public immutable i_harness;
    address[] public s_buyers;

    /// @dev What the venue leg reported buying, and what has been paid back out of the books. Read
    ///      off the contract's own return/getter values rather than recomputed from the allocation, so
    ///      the ghost cannot become a second copy of the arithmetic under test.
    uint256 public s_rbtcBoughtGhost;
    uint256 public s_rbtcWithdrawnGhost;
    /// @dev Total slack the floor allocation is allowed: under one wei per row, summed over batches.
    uint256 public s_flooredSlackGhost;
    uint256 public s_batchSuccesses;
    uint256 public s_withdrawSuccesses;

    constructor(PurchaseRbtcHarness harness, address[] memory buyers) {
        i_harness = harness;
        s_buyers = buyers;
    }

    function buyersLength() external view returns (uint256) {
        return s_buyers.length;
    }

    /**
     * @notice Run one batch with a fuzzed shape and a fuzzed venue output.
     * @dev `rbtcOut` is what the harness's `_purchaseRbtc` reports measuring, which is the quantity
     *      the allocation must hand out in full.
     */
    function batchBuyRbtc(uint256 rowSeed, uint256 amountSeed, uint256 rbtcOutSeed, uint256 buyerSeed) external {
        uint256 rows = bound(rowSeed, 1, MAX_ROWS);
        address[] memory buyers = new address[](rows);
        uint64[] memory scheduleIds = new uint64[](rows);
        uint256[] memory amounts = new uint256[](rows);

        for (uint256 i; i < rows; ++i) {
            // Vary every row's weight so the pro-rata shares actually truncate.
            uint256 mixed = uint256(keccak256(abi.encode(amountSeed, i)));
            buyers[i] = s_buyers[uint256(keccak256(abi.encode(buyerSeed, i))) % s_buyers.length];
            scheduleIds[i] = uint64(i + 1);
            amounts[i] = bound(mixed, MIN_AMOUNT, MAX_AMOUNT);
        }

        uint256 rbtcOut = bound(rbtcOutSeed, 1, 100 ether);
        i_harness.setRbtcOut(rbtcOut);
        // The harness pays its books in native rBTC, so it must actually hold what it says it bought.
        vm.deal(address(i_harness), address(i_harness).balance + rbtcOut);

        try i_harness.batchBuyRbtc(buyers, scheduleIds, amounts, 0) {
            s_rbtcBoughtGhost += rbtcOut;
            s_flooredSlackGhost += rows - 1;
            ++s_batchSuccesses;
        } catch {
            // An unlucky draw (retrieval at or below the aggregated fee) is not a finding.
        }
    }

    /// @notice Pay one buyer's whole accumulated balance out of the books.
    function withdrawAccumulatedRbtc(uint256 buyerSeed) external {
        address buyer = s_buyers[buyerSeed % s_buyers.length];
        uint256 owed = i_harness.getAccumulatedRbtcBalance(buyer);

        try i_harness.withdrawAccumulatedRbtc(buyer) {
            s_rbtcWithdrawnGhost += owed;
            ++s_withdrawSuccesses;
        } catch {
            // Nothing accumulated yet.
        }
    }
}

/**
 * @title PurchaseRbtcConservationInvariantTest
 * @notice Measured rBTC is attributed to buyers up to the floor allocation's stated slack, never past it.
 * @dev Targets the real `PurchaseRbtc` through `PurchaseRbtcHarness`, which overrides only the venue
 *      and retrieval legs. The main fuzz suite in `Invariants.t.sol` cannot cover this: the handlers
 *      it targets reimplement `batchBuyRbtc`, so the allocation loop never runs there.
 *
 *      Named `...InvariantTest` so the `make invariants` lane (`--match-contract InvariantTest`)
 *      picks it up with no Makefile change.
 */
contract PurchaseRbtcConservationInvariantTest is StdInvariant, Test {
    uint16 internal constant FLAT_FEE_RATE = 100; // 1%
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    MockStablecoin internal token;
    PurchaseRbtcHarness internal harness;
    PurchaseRbtcConservationHandler internal fuzzHandler;
    address[] internal s_buyers;

    function setUp() public {
        token = new MockStablecoin(address(this));

        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });

        for (uint256 i; i < 5; ++i) {
            s_buyers.push(address(uint160(0xB0B00 + i)));
        }

        // dcaManager = the fuzz handler, so it can call the `onlyDcaManager` entry points directly.
        address predictedFuzzHandler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        harness = new PurchaseRbtcHarness(
            predictedFuzzHandler, address(token), address(0xFEE), feeSettings, address(this)
        );
        fuzzHandler = new PurchaseRbtcConservationHandler(harness, s_buyers);
        assertEq(address(fuzzHandler), predictedFuzzHandler, "dcaManager wiring missed the fuzz handler");

        token.mint(address(harness), type(uint128).max);

        targetContract(address(fuzzHandler));
    }

    /// @dev Coverage guard: if no batch ever lands, the invariant below is 0 == 0 for the whole run.
    function test_conservationHandlerLandsABatchAndAWithdrawal() public {
        fuzzHandler.batchBuyRbtc(4, 12345, 7 ether, 1);
        assertEq(fuzzHandler.s_batchSuccesses(), 1, "the fuzz action never reached batchBuyRbtc");
        assertGt(fuzzHandler.s_rbtcBoughtGhost(), 0, "no rBTC was measured as bought");

        for (uint256 i; i < s_buyers.length; ++i) {
            fuzzHandler.withdrawAccumulatedRbtc(i);
        }
        assertGt(fuzzHandler.s_withdrawSuccesses(), 0, "no buyer could withdraw what the batch credited");
    }

    /**
     * @notice Credits plus payouts land inside the band the floor allocation is allowed.
     * @dev The upper bound is the safety property: the books must never claim more rBTC than the venue
     *      leg delivered, or a withdrawal eventually finds nothing behind it. The lower bound is the
     *      accuracy property, and it is what a plain `<=` would miss — that one holds even if the
     *      allocation credited nobody. Together they still catch a wrong denominator, a skipped row or
     *      a double credit, while allowing the under-one-wei-per-row residue that is accepted by design.
     */
    function invariant_creditsStayWithinTheFlooredBand() public {
        uint256 totalOnBooks;
        for (uint256 i; i < s_buyers.length; ++i) {
            totalOnBooks += harness.getAccumulatedRbtcBalance(s_buyers[i]);
        }

        uint256 attributed = totalOnBooks + fuzzHandler.s_rbtcWithdrawnGhost();
        uint256 bought = fuzzHandler.s_rbtcBoughtGhost();

        assertLe(attributed, bought, "books claim more rBTC than the venue leg delivered");
        assertGe(
            attributed + fuzzHandler.s_flooredSlackGhost(),
            bought,
            "measured rBTC went missing beyond the floor allocation's slack"
        );
    }

    /// @notice The handler always holds at least the rBTC it owes.
    function invariant_booksNeverExceedHandlerBalance() public {
        uint256 totalOnBooks;
        for (uint256 i; i < s_buyers.length; ++i) {
            totalOnBooks += harness.getAccumulatedRbtcBalance(s_buyers[i]);
        }
        assertLe(totalOnBooks, address(harness).balance, "handler owes more rBTC than it holds");
    }
}
