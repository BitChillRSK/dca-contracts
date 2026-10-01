// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
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
 *      real shared pipeline. Expected-empty cases return early; production calls are not wrapped in
 *      try/catch so `fail_on_revert` surfaces handler regressions.
 */
contract LendingPurchaseConservationHandler is Test {
    uint256 internal constant MIN_AMOUNT = 25 ether;
    uint256 internal constant MAX_AMOUNT = 10_000 ether;
    uint256 internal constant MAX_SCHEDULE_ID = 64;
    uint256 internal constant EXCHANGE_RATE_DECIMALS = 1e18;

    SovrynDocHandlerMoc public immutable i_handler;
    MockStablecoin public immutable i_doc;
    MockIsusdToken public immutable i_iToken;
    address[] public s_users;

    uint256 public s_depositSuccesses;
    uint256 public s_buySuccesses;
    uint256 public s_withdrawSuccesses;
    /// @dev Sum of handler native-balance gains measured around successful purchases.
    uint256 public s_rbtcReceivedGhost;
    /// @dev Sum of user native-balance gains measured around successful withdrawals.
    uint256 public s_rbtcWithdrawnGhost;

    constructor(SovrynDocHandlerMoc handler, MockStablecoin doc, MockIsusdToken iSusd, address[] memory users) {
        i_handler = handler;
        i_doc = doc;
        i_iToken = iSusd;
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

        i_handler.depositToken(user, amount);
        ++s_depositSuccesses;
    }

    /**
     * @notice Redeem through MoC and credit rBTC for one buyer via the production purchase pipeline.
     * @dev Schedule ids are free labels here: `PurchaseRbtc` only uses them in events. Skip when the
     *      user cannot cover a minimum purchase from their share-backed position; otherwise call the
     *      leaf directly so a production revert fails the invariant run.
     */
    function buyRbtc(uint256 userSeed, uint256 amountSeed, uint256 scheduleSeed) external {
        address user = s_users[userSeed % s_users.length];
        uint256 available = _shareBackedStablecoin(user);
        if (available < MIN_AMOUNT) return;

        uint256 amount = bound(amountSeed, MIN_AMOUNT, available < MAX_AMOUNT ? available : MAX_AMOUNT);
        uint64 scheduleId = uint64(bound(scheduleSeed, 1, MAX_SCHEDULE_ID));

        address[] memory buyers = new address[](1);
        buyers[0] = user;
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = scheduleId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        uint256 handlerBalBefore = address(i_handler).balance;
        uint256 collectorBefore = address(0xFEE).balance;
        i_handler.batchBuyRbtc(buyers, scheduleIds, amounts, 0);
        s_rbtcReceivedGhost += (address(i_handler).balance - handlerBalBefore)
            + (address(0xFEE).balance - collectorBefore);
        ++s_buySuccesses;
    }

    /// @notice Pay one buyer's whole accumulated rBTC balance out of the books.
    function withdrawAccumulatedRbtc(uint256 userSeed) external {
        address user = s_users[userSeed % s_users.length];
        if (IPurchaseRbtc(address(i_handler)).getAccumulatedRbtcBalance(user) == 0) return;

        uint256 userBalBefore = user.balance;
        i_handler.withdrawAccumulatedRbtc(user);
        s_rbtcWithdrawnGhost += user.balance - userBalBefore;
        ++s_withdrawSuccesses;
    }

    /// @dev Round-down share → stablecoin, matching LendingHandler's withdrawable ceiling.
    function _shareBackedStablecoin(address user) private view returns (uint256) {
        return ILendingHandler(address(i_handler)).getUserShares(user) * i_iToken.tokenPrice() / EXCHANGE_RATE_DECIMALS;
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
        IPurchaseFees.FeeSettings memory feeSettings = IPurchaseFees.FeeSettings({
            minFeeRate: FLAT_FEE_RATE, maxFeeRate: FLAT_FEE_RATE, feePurchaseLowerBound: 1000 ether
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
        fuzzHandler = new LendingPurchaseConservationHandler(handler, doc, iSusd, s_users);
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

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = LendingPurchaseConservationHandler.depositToken.selector;
        selectors[1] = LendingPurchaseConservationHandler.buyRbtc.selector;
        selectors[2] = LendingPurchaseConservationHandler.withdrawAccumulatedRbtc.selector;
        targetContract(address(fuzzHandler));
        targetSelector(FuzzSelector({addr: address(fuzzHandler), selectors: selectors}));
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
        assertGt(fuzzHandler.s_rbtcReceivedGhost(), 0, "ghost missed the MoC payout");
        assertEq(doc.balanceOf(address(handler)), 0, "DOC left idle after the purchase");

        fuzzHandler.withdrawAccumulatedRbtc(0);
        assertEq(fuzzHandler.s_withdrawSuccesses(), 1, "withdraw never reached PurchaseRbtc");
        assertEq(IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(s_users[0]), 0, "books not cleared");
        assertEq(
            address(handler).balance + fuzzHandler.s_rbtcWithdrawnGhost(),
            fuzzHandler.s_rbtcReceivedGhost(),
            "native rBTC left the (handler, users) closed set"
        );
    }

    /**
     * @notice MoC-paid rBTC is on the handler (buyer claims + collector credit + floor dust)
     *         or already paid to a withdrawer. Length-1 batches can leave one wei of floor dust.
     */
    function invariant_rbtcNativeConservation() public {
        uint256 claimable;
        for (uint256 i; i < s_users.length; ++i) {
            claimable += IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(s_users[i]);
        }
        claimable += IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(FEE_COLLECTOR);

        assertLe(claimable, address(handler).balance, "claimable rBTC exceeds handler native balance");
        assertEq(
            address(handler).balance + fuzzHandler.s_rbtcWithdrawnGhost(),
            fuzzHandler.s_rbtcReceivedGhost(),
            "received rBTC is not conserved across handler residual and withdrawals"
        );
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
