// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {PurchaseRbtcHarness} from "test/unit/PurchaseRbtcTest.t.sol";

/**
 * @title PurchaseRbtcConservationHandler
 * @notice Fuzz actions over the real `PurchaseRbtc` batch pipeline.
 * @dev Drives `batchBuyRbtc` at random row counts, weights, and venue outputs; withdraws for
 *      buyers and collectors; rotates the fee collector (including onto a buyer). Purchases are
 *      not wrapped in try/catch: the harness always delivers a full retrieval and a positive venue
 *      output, so a revert is a finding (`fail_on_revert`). Empty withdrawals return early instead
 *      of catching `NoAccumulatedRbtcToWithdraw`.
 */
contract PurchaseRbtcConservationHandler is Test {
    uint256 internal constant MAX_ROWS = 12;
    /// @dev Distinct purchase sizes keep the allocation weights unequal.
    uint256 internal constant MIN_AMOUNT = 1 ether;
    uint256 internal constant MAX_AMOUNT = 500_000 ether;

    PurchaseRbtcHarness public immutable i_harness;
    address[] public s_buyers;
    address[] public s_collectors;
    address public s_feeCollector;

    /// @dev What the venue leg reported buying, and what has been paid back out of the books. Read
    ///      off the contract's own return/getter values rather than recomputed from the allocation, so
    ///      the ghost cannot become a second copy of the arithmetic under test.
    uint256 public s_rbtcBoughtGhost;
    uint256 public s_rbtcWithdrawnGhost;
    /// @dev Total slack the floor allocation is allowed: under one wei per row, summed over batches.
    uint256 public s_flooredSlackGhost;
    uint256 public s_batchSuccesses;
    uint256 public s_withdrawSuccesses;
    uint256 public s_collectorRotateSuccesses;

    constructor(PurchaseRbtcHarness harness, address[] memory buyers, address initialCollector) {
        i_harness = harness;
        s_buyers = buyers;
        s_feeCollector = initialCollector;
        s_collectors.push(initialCollector);
    }

    function buyersLength() external view returns (uint256) {
        return s_buyers.length;
    }

    function collectorsLength() external view returns (uint256) {
        return s_collectors.length;
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

        i_harness.batchBuyRbtc(buyers, scheduleIds, amounts, 0);
        s_rbtcBoughtGhost += rbtcOut;
        // k = rows + 1 floors (buyers + fee) leave at most k-1 = rows wei uncredited.
        s_flooredSlackGhost += rows;
        ++s_batchSuccesses;
    }

    /// @notice Pay one buyer's or collector's whole accumulated balance out of the books.
    function withdrawAccumulatedRbtc(uint256 accountSeed) external {
        address account = _account(accountSeed);
        uint256 owed = i_harness.getAccumulatedRbtcBalance(account);
        if (owed == 0) return;

        i_harness.withdrawAccumulatedRbtc(account);
        s_rbtcWithdrawnGhost += owed;
        ++s_withdrawSuccesses;
    }

    /// @notice Point fees at a buyer (overlap) or a dedicated spare collector address.
    function rotateFeeCollector(uint256 seed) external {
        address next;
        if (seed % 5 == 0) {
            next = address(uint160(0xFEE0 + (seed % 3)));
        } else {
            next = s_buyers[seed % s_buyers.length];
        }
        if (next == s_feeCollector || next == address(0)) return;

        i_harness.setFeeCollector(next);
        s_feeCollector = next;
        _rememberCollector(next);
        ++s_collectorRotateSuccesses;
    }

    function _account(uint256 seed) private view returns (address) {
        uint256 buyerCount = s_buyers.length;
        uint256 total = buyerCount + s_collectors.length;
        uint256 idx = seed % total;
        if (idx < buyerCount) return s_buyers[idx];
        return s_collectors[idx - buyerCount];
    }

    function _rememberCollector(address collector) private {
        for (uint256 i; i < s_collectors.length; ++i) {
            if (s_collectors[i] == collector) return;
        }
        s_collectors.push(collector);
    }
}

/**
 * @title PurchaseRbtcConservationInvariantBase
 * @notice Shared conservation invariants; concrete suites pick flat or launch variable fees.
 */
abstract contract PurchaseRbtcConservationInvariantBase is StdInvariant, Test {
    address internal constant INITIAL_COLLECTOR = address(0xFEE);

    MockStablecoin internal token;
    PurchaseRbtcHarness internal harness;
    PurchaseRbtcConservationHandler internal fuzzHandler;
    address[] internal s_buyers;

    function _feeSettings() internal pure virtual returns (IPurchaseFees.FeeSettings memory);

    function setUp() public {
        token = new MockStablecoin(address(this));

        for (uint256 i; i < 5; ++i) {
            s_buyers.push(address(uint160(0xB0B00 + i)));
        }

        address predictedFuzzHandler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        harness = new PurchaseRbtcHarness(
            predictedFuzzHandler, address(token), INITIAL_COLLECTOR, _feeSettings(), predictedFuzzHandler
        );
        fuzzHandler = new PurchaseRbtcConservationHandler(harness, s_buyers, INITIAL_COLLECTOR);
        assertEq(address(fuzzHandler), predictedFuzzHandler, "dcaManager/owner wiring missed the fuzz handler");

        token.mint(address(harness), type(uint128).max);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PurchaseRbtcConservationHandler.batchBuyRbtc.selector;
        selectors[1] = PurchaseRbtcConservationHandler.withdrawAccumulatedRbtc.selector;
        selectors[2] = PurchaseRbtcConservationHandler.rotateFeeCollector.selector;
        targetContract(address(fuzzHandler));
        targetSelector(FuzzSelector({addr: address(fuzzHandler), selectors: selectors}));
    }

    /// @dev Coverage guard: if no batch ever lands, the invariant below is 0 == 0 for the whole run.
    function test_conservationHandlerLandsABatchAndAWithdrawal() public {
        fuzzHandler.batchBuyRbtc(4, 12345, 7 ether, 1);
        assertEq(fuzzHandler.s_batchSuccesses(), 1, "the fuzz action never reached batchBuyRbtc");
        assertGt(fuzzHandler.s_rbtcBoughtGhost(), 0, "no rBTC was measured as bought");

        fuzzHandler.rotateFeeCollector(1);
        assertEq(fuzzHandler.s_collectorRotateSuccesses(), 1, "collector rotation never landed");

        for (uint256 i; i < s_buyers.length + fuzzHandler.collectorsLength(); ++i) {
            fuzzHandler.withdrawAccumulatedRbtc(i);
        }
        assertGt(fuzzHandler.s_withdrawSuccesses(), 0, "no account could withdraw what the batch credited");
    }

    /**
     * @notice Credits plus payouts land inside the band the floor allocation is allowed.
     * @dev Unique claimables across buyers and collectors — overlap must not double-count.
     */
    function invariant_creditsStayWithinTheFlooredBand() public {
        uint256 claimable = _uniqueClaimable();
        uint256 attributed = claimable + fuzzHandler.s_rbtcWithdrawnGhost();
        uint256 bought = fuzzHandler.s_rbtcBoughtGhost();

        assertLe(attributed, bought, "books plus payouts claim more rBTC than the venue delivered");
        assertGe(
            attributed + fuzzHandler.s_flooredSlackGhost(),
            bought,
            "measured rBTC went missing beyond the floor allocation's slack"
        );
    }

    /// @notice The handler always holds at least the rBTC it owes.
    function invariant_booksNeverExceedHandlerBalance() public {
        assertLe(_uniqueClaimable(), address(harness).balance, "handler owes more rBTC than it holds");
    }

    function _uniqueClaimable() private view returns (uint256 total) {
        address[] memory seen = new address[](s_buyers.length + fuzzHandler.collectorsLength());
        uint256 seenCount;

        for (uint256 i; i < s_buyers.length; ++i) {
            seenCount = _addUnique(seen, seenCount, s_buyers[i]);
        }
        for (uint256 i; i < fuzzHandler.collectorsLength(); ++i) {
            seenCount = _addUnique(seen, seenCount, fuzzHandler.s_collectors(i));
        }
        for (uint256 i; i < seenCount; ++i) {
            total += harness.getAccumulatedRbtcBalance(seen[i]);
        }
    }

    function _addUnique(address[] memory seen, uint256 seenCount, address account) private pure returns (uint256) {
        for (uint256 i; i < seenCount; ++i) {
            if (seen[i] == account) return seenCount;
        }
        seen[seenCount] = account;
        return seenCount + 1;
    }
}

/// @notice Flat 100 bps fees (historical conservation configuration).
contract PurchaseRbtcConservationInvariantTest is PurchaseRbtcConservationInvariantBase {
    uint16 internal constant FLAT_FEE_RATE = 100;

    function _feeSettings() internal pure override returns (IPurchaseFees.FeeSettings memory) {
        return IPurchaseFees.FeeSettings({
            minFeeRate: FLAT_FEE_RATE, maxFeeRate: FLAT_FEE_RATE, feePurchaseLowerBound: 1000 ether
        });
    }
}

/// @notice Launch variable-fee band: 100/20 bps, 250-token lower bound.
contract PurchaseRbtcVariableFeeConservationInvariantTest is PurchaseRbtcConservationInvariantBase {
    function _feeSettings() internal pure override returns (IPurchaseFees.FeeSettings memory) {
        return IPurchaseFees.FeeSettings({minFeeRate: 20, maxFeeRate: 100, feePurchaseLowerBound: 250 ether});
    }
}
