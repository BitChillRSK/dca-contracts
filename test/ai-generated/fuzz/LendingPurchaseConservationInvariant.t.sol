// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {ILendingHandler} from "src/interfaces/ILendingHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";

/**
 * @title LendingPurchaseConservationHandler
 * @notice Fuzz actions over production Sovryn lending + production `PurchaseRbtc` (via MoC).
 * @dev The fuzz actor is the handler's `dcaManager`, so it can call `onlyDcaManager` entry points
 *      directly. Deposits mint iSUSD; purchases redeem through `MockMocProxy` and credit through the
 *      real shared pipeline. Swallows expected reverts so `fail_on_revert` surfaces protocol breaks.
 */
contract LendingPurchaseConservationHandler is Test {
    uint256 internal constant MIN_AMOUNT = 25 ether;
    uint256 internal constant MAX_AMOUNT = 10_000 ether;
    uint256 internal constant MAX_SCHEDULE_ID = 64;

    SovrynDocHandlerMoc public immutable i_handler;
    MockStablecoin public immutable i_doc;
    address[] public s_users;

    uint256 public s_depositSuccesses;
    uint256 public s_buySuccesses;
    uint256 public s_withdrawSuccesses;
    uint256 public s_rbtcBoughtGhost;
    uint256 public s_rbtcWithdrawnGhost;

    constructor(SovrynDocHandlerMoc handler, MockStablecoin doc, address[] memory users) {
        i_handler = handler;
        i_doc = doc;
        s_users = users;
    }

    function usersLength() external view returns (uint256) {
        return s_users.length;
    }

    /// @notice Deposit DOC into Sovryn lending for a fuzzed user.
    function depositToken(uint256 userSeed, uint256 amountSeed) external {
        address user = s_users[userSeed % s_users.length];
        uint256 amount = bound(amountSeed, MIN_AMOUNT, MAX_AMOUNT);

        uint256 balance = i_doc.balanceOf(user);
        if (balance < amount) {
            i_doc.mint(user, amount - balance);
        }

        try i_handler.depositToken(user, amount) {
            ++s_depositSuccesses;
        } catch {
            // Maxed books or an unlucky draw.
        }
    }

    /**
     * @notice Redeem through MoC and credit rBTC for one buyer via the production purchase pipeline.
     * @dev Schedule ids are free labels here: `PurchaseRbtc` only uses them in events. The amount is
     *      what `_batchRetrieveStablecoin` burns from the buyer's lending position. Call the leaf's
     *      `batchBuyRbtc` directly (not a public helper) so the fuzzer cannot hit an internal-only
     *      entry point under `fail_on_revert`.
     */
    function buyRbtc(uint256 userSeed, uint256 amountSeed, uint256 scheduleSeed) external {
        address user = s_users[userSeed % s_users.length];
        uint256 amount = bound(amountSeed, MIN_AMOUNT, MAX_AMOUNT);
        uint64 scheduleId = uint64(bound(scheduleSeed, 1, MAX_SCHEDULE_ID));

        address[] memory buyers = new address[](1);
        buyers[0] = user;
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = scheduleId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        uint256 rbtcBefore = IPurchaseRbtc(address(i_handler)).getAccumulatedRbtcBalance(user);
        try i_handler.batchBuyRbtc(buyers, scheduleIds, amounts, 0) {
            uint256 credited = IPurchaseRbtc(address(i_handler)).getAccumulatedRbtcBalance(user) - rbtcBefore;
            s_rbtcBoughtGhost += credited;
            ++s_buySuccesses;
        } catch {
            // Insufficient shares, fee floor, or MoC shortfall.
        }
    }

    /// @notice Pay one buyer's whole accumulated rBTC balance out of the books.
    function withdrawAccumulatedRbtc(uint256 userSeed) external {
        address user = s_users[userSeed % s_users.length];
        uint256 owed = IPurchaseRbtc(address(i_handler)).getAccumulatedRbtcBalance(user);

        try i_handler.withdrawAccumulatedRbtc(user) {
            s_rbtcWithdrawnGhost += owed;
            ++s_withdrawSuccesses;
        } catch {
            // Nothing accumulated yet.
        }
    }
}

/**
 * @title LendingPurchaseConservationInvariantTest
 * @notice Production lending handler + production `PurchaseRbtc` under one conservation harness.
 * @dev The main `InvariantTest` wrappers reimplement purchase, and `PurchaseRbtcConservationInvariantTest`
 *      skips lending. This suite is the missing middle: `SovrynDocHandlerMoc` runs both halves for real.
 *
 *      Named `…InvariantTest` so `make invariants` / `make invariants-sovryn` pick it up with no Makefile
 *      change.
 */
contract LendingPurchaseConservationInvariantTest is StdInvariant, Test {
    uint16 internal constant FLAT_FEE_RATE = 100; // 1%
    address internal constant FEE_COLLECTOR = address(0xFEE);

    MockStablecoin internal doc;
    MockIsusdToken internal iSusd;
    MockMocProxy internal mocProxy;
    SovrynDocHandlerMoc internal handler;
    LendingPurchaseConservationHandler internal fuzzHandler;
    address[] internal s_users;

    function setUp() public {
        doc = new MockStablecoin(address(this));
        iSusd = new MockIsusdToken(address(doc));
        mocProxy = new MockMocProxy(address(doc));
        // MoC pays native rBTC on redeem; keep a cushion for the whole fuzz run.
        vm.deal(address(mocProxy), 1_000_000 ether);

        for (uint256 i; i < 5; ++i) {
            s_users.push(address(uint160(0xC0FFEE + i)));
        }

        address predictedFuzzHandler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        handler = new SovrynDocHandlerMoc(
            predictedFuzzHandler,
            address(doc),
            address(iSusd),
            FEE_COLLECTOR,
            address(mocProxy),
            feeSettings,
            address(this)
        );
        fuzzHandler = new LendingPurchaseConservationHandler(handler, doc, s_users);
        assertEq(address(fuzzHandler), predictedFuzzHandler, "dcaManager wiring missed the fuzz handler");

        // Local MockMocProxy pulls DOC via transferFrom; live MoC does not. Same fixture step as
        // SovrynDocHandlerMocTest / DcaDappTest Anvil setup.
        vm.prank(address(handler));
        doc.approve(address(mocProxy), type(uint256).max);

        for (uint256 i; i < s_users.length; ++i) {
            address user = s_users[i];
            doc.mint(user, 1_000_000 ether);
            vm.prank(user);
            doc.approve(address(handler), type(uint256).max);
        }

        targetContract(address(fuzzHandler));
    }

    /// @dev Coverage guard: deposit → purchase → withdraw must all land on the production leaf.
    function test_lendingPurchaseHandlerLandsDepositBuyAndWithdraw() public {
        fuzzHandler.depositToken(0, 1_000 ether);
        assertEq(fuzzHandler.s_depositSuccesses(), 1, "deposit never reached the lending leaf");
        assertGt(ILendingHandler(address(handler)).getUserShares(s_users[0]), 0, "no shares credited");

        uint256 sharesBefore = ILendingHandler(address(handler)).getUserShares(s_users[0]);
        fuzzHandler.buyRbtc(0, 100 ether, 1);
        assertEq(fuzzHandler.s_buySuccesses(), 1, "purchase never reached PurchaseRbtc");
        assertLt(ILendingHandler(address(handler)).getUserShares(s_users[0]), sharesBefore, "purchase burned no shares");
        assertGt(
            IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(s_users[0]),
            0,
            "purchase credited no rBTC through the real pipeline"
        );
        assertGt(fuzzHandler.s_rbtcBoughtGhost(), 0, "ghost missed the credit");

        // MockMocProxy pays `doc / BTC_PRICE`; a 100 DOC net buy is far below 1 rBTC.
        assertGt(address(handler).balance, 0, "MoC paid no rBTC into the handler");
        assertEq(doc.balanceOf(address(handler)), 0, "DOC left idle after the purchase");

        fuzzHandler.withdrawAccumulatedRbtc(0);
        assertEq(fuzzHandler.s_withdrawSuccesses(), 1, "withdraw never reached PurchaseRbtc");
        assertEq(IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(s_users[0]), 0, "books not cleared");
    }

    /// @notice Claimable rBTC never exceeds the handler's native balance.
    function invariant_booksNeverExceedHandlerBalance() public {
        uint256 totalOnBooks;
        for (uint256 i; i < s_users.length; ++i) {
            totalOnBooks += IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(s_users[i]);
        }
        assertLe(totalOnBooks, address(handler).balance, "handler owes more rBTC than it holds");
    }

    /// @notice Virtual lending shares never exceed the iSUSD the leaf actually holds.
    function invariant_virtualSharesNeverExceedReceiptShares() public {
        uint256 totalVirtual;
        for (uint256 i; i < s_users.length; ++i) {
            totalVirtual += ILendingHandler(address(handler)).getUserShares(s_users[i]);
        }
        assertLe(totalVirtual, iSusd.balanceOf(address(handler)), "virtual shares exceed iSUSD held");
    }

    /// @notice Successful ops leave no idle DOC on the handler.
    function invariant_handlerStablecoinBalanceZero() public {
        assertEq(doc.balanceOf(address(handler)), 0, "idle DOC left on the production leaf");
    }
}
