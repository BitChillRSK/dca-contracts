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
 * @dev The fuzz actor is the handler's `dcaManager` and owner, so it can call `onlyDcaManager`
 *      entry points and rotate the fee collector. Deposits mint iSUSD; purchases redeem through
 *      `MockMocProxy` and credit through the real shared pipeline under launch variable fees.
 *      Expected-empty cases return early; production calls are not wrapped in try/catch so
 *      `fail_on_revert` surfaces handler regressions.
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
    address[] public s_collectors;
    address public s_feeCollector;

    uint256 public s_depositSuccesses;
    uint256 public s_buySuccesses;
    uint256 public s_withdrawSuccesses;
    uint256 public s_collectorRotateSuccesses;
    /// @dev Sum of handler native-balance gains measured around successful purchases.
    uint256 public s_rbtcReceivedGhost;
    /// @dev Sum of recipient native-balance gains measured around successful withdrawals.
    uint256 public s_rbtcWithdrawnGhost;

    constructor(
        SovrynDocHandlerMoc handler,
        MockStablecoin doc,
        MockIsusdToken iSusd,
        address[] memory users,
        address initialCollector
    ) {
        i_handler = handler;
        i_doc = doc;
        i_iToken = iSusd;
        s_users = users;
        s_feeCollector = initialCollector;
        s_collectors.push(initialCollector);
    }

    function usersLength() external view returns (uint256) {
        return s_users.length;
    }

    function collectorsLength() external view returns (uint256) {
        return s_collectors.length;
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

        // Fees stay on the handler books until withdrawn — measure only the MoC payout onto the leaf.
        uint256 handlerBalBefore = address(i_handler).balance;
        i_handler.batchBuyRbtc(buyers, scheduleIds, amounts, 0);
        s_rbtcReceivedGhost += address(i_handler).balance - handlerBalBefore;
        ++s_buySuccesses;
    }

    /// @notice Pay one user's or collector's whole accumulated rBTC balance out of the books.
    function withdrawAccumulatedRbtc(uint256 accountSeed) external {
        address account = _account(accountSeed);
        if (IPurchaseRbtc(address(i_handler)).getAccumulatedRbtcBalance(account) == 0) return;

        uint256 balBefore = account.balance;
        i_handler.withdrawAccumulatedRbtc(account);
        s_rbtcWithdrawnGhost += account.balance - balBefore;
        ++s_withdrawSuccesses;
    }

    /**
     * @notice Point fees at a user (overlap) or a dedicated spare collector address.
     * @dev Prior credits stay with the old collector; only subsequent purchases go to `next`.
     */
    function rotateFeeCollector(uint256 seed) external {
        address next;
        if (seed % 5 == 0) {
            next = address(uint160(0xFEE0 + (seed % 3)));
        } else {
            next = s_users[seed % s_users.length];
        }
        if (next == s_feeCollector || next == address(0)) return;

        i_handler.setFeeCollector(next);
        s_feeCollector = next;
        _rememberCollector(next);
        ++s_collectorRotateSuccesses;
    }

    /// @dev Round-down share → stablecoin, matching LendingHandler's withdrawable ceiling.
    function _shareBackedStablecoin(address user) private view returns (uint256) {
        return ILendingHandler(address(i_handler)).getUserShares(user) * i_iToken.tokenPrice() / EXCHANGE_RATE_DECIMALS;
    }

    function _account(uint256 seed) private view returns (address) {
        uint256 userCount = s_users.length;
        uint256 total = userCount + s_collectors.length;
        uint256 idx = seed % total;
        if (idx < userCount) return s_users[idx];
        return s_collectors[idx - userCount];
    }

    function _rememberCollector(address collector) private {
        for (uint256 i; i < s_collectors.length; ++i) {
            if (s_collectors[i] == collector) return;
        }
        s_collectors.push(collector);
    }
}

/**
 * @title LendingPurchaseConservationInvariantTest
 * @notice Production lending handler + production `PurchaseRbtc` under one conservation harness.
 * @dev The main `InvariantTest` wrappers reimplement purchase, and `PurchaseRbtcConservationInvariantTest`
 *      skips lending. This suite is the missing middle: `SovrynDocHandlerMoc` runs both halves for real
 *      under launch variable fees with collector withdraw/rotation. Named `…InvariantTest` so
 *      `make invariants` / `make invariants-sovryn` pick it up with no Makefile change.
 */
contract LendingPurchaseConservationInvariantTest is StdInvariant, Test {
    uint16 internal constant MIN_FEE_RATE = 20;
    uint16 internal constant MAX_FEE_RATE = 100;
    uint112 internal constant FEE_PURCHASE_LOWER_BOUND = 250 ether;
    address internal constant INITIAL_COLLECTOR = address(0xFEE);

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
            minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
        });
        handler = new SovrynDocHandlerMoc(
            predictedFuzzHandler,
            address(doc),
            address(iSusd),
            INITIAL_COLLECTOR,
            address(mocProxy),
            feeSettings,
            predictedFuzzHandler
        );
        fuzzHandler = new LendingPurchaseConservationHandler(handler, doc, iSusd, s_users, INITIAL_COLLECTOR);
        assertEq(address(fuzzHandler), predictedFuzzHandler, "dcaManager/owner wiring missed the fuzz handler");

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

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = LendingPurchaseConservationHandler.depositToken.selector;
        selectors[1] = LendingPurchaseConservationHandler.buyRbtc.selector;
        selectors[2] = LendingPurchaseConservationHandler.withdrawAccumulatedRbtc.selector;
        selectors[3] = LendingPurchaseConservationHandler.rotateFeeCollector.selector;
        targetContract(address(fuzzHandler));
        targetSelector(FuzzSelector({addr: address(fuzzHandler), selectors: selectors}));
    }

    /// @dev Coverage guard: deposit → purchase → rotate → withdraw must all land on the production leaf.
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
        assertGt(
            IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(INITIAL_COLLECTOR),
            0,
            "variable-fee purchase credited no collector share"
        );
        assertGt(fuzzHandler.s_rbtcReceivedGhost(), 0, "ghost missed the MoC payout");
        assertEq(doc.balanceOf(address(handler)), 0, "DOC left idle after the purchase");

        fuzzHandler.rotateFeeCollector(1);
        assertEq(fuzzHandler.s_collectorRotateSuccesses(), 1, "collector rotation never landed");

        fuzzHandler.withdrawAccumulatedRbtc(0);
        fuzzHandler.withdrawAccumulatedRbtc(s_users.length); // initial collector index in _account
        assertGt(fuzzHandler.s_withdrawSuccesses(), 0, "withdraw never reached PurchaseRbtc");
        assertEq(
            address(handler).balance + fuzzHandler.s_rbtcWithdrawnGhost(),
            fuzzHandler.s_rbtcReceivedGhost(),
            "native rBTC left the (handler, recipients) closed set"
        );
    }

    /**
     * @notice MoC-paid rBTC is on the handler (unique claimables + floor dust) or already paid out.
     *         Length-1 batches can leave one wei of floor dust on the handler.
     */
    function invariant_rbtcNativeConservation() public {
        uint256 claimable = _uniqueClaimable();

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

    function _uniqueClaimable() private view returns (uint256 total) {
        address[] memory seen = new address[](s_users.length + fuzzHandler.collectorsLength());
        uint256 seenCount;

        for (uint256 i; i < s_users.length; ++i) {
            seenCount = _addUnique(seen, seenCount, s_users[i]);
        }
        for (uint256 i; i < fuzzHandler.collectorsLength(); ++i) {
            seenCount = _addUnique(seen, seenCount, fuzzHandler.s_collectors(i));
        }
        for (uint256 i; i < seenCount; ++i) {
            total += IPurchaseRbtc(address(handler)).getAccumulatedRbtcBalance(seen[i]);
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
