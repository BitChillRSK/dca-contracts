// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
import {SovrynErc20Handler} from "src/sovryn/SovrynErc20Handler.sol";
import {IdleErc20Handler} from "src/idle/IdleErc20Handler.sol";
import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {StablecoinSource} from "src/StablecoinSource.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";

/**
 * @notice Storage slots the R79 tests read directly. `setUp` in each R79 suite re-derives them from a
 *         real credit, deposit, or debit, so a layout change fails loudly instead of reading the wrong
 *         word. Re-check with `forge inspect R79SovrynHandler storage-layout` (and the idle one).
 */
library R79Slots {
    /// @dev `PurchaseRbtc.s_usersAccumulatedRbtc` on both stub handlers.
    uint256 internal constant ACCUMULATED_RBTC = 5;
    /// @dev `LendingErc20Handler.s_shares` on `R79SovrynHandler`.
    uint256 internal constant SHARES = 4;
    /// @dev `IdleErc20Handler.s_idleBalances` on `R79IdleHandler`.
    uint256 internal constant IDLE_BALANCES = 4;

    function key(address user, uint256 base) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, base));
    }
}

/**
 * @notice Sovryn lending handler whose venue takes the net stablecoin and reports a fixed rBTC figure.
 *         Everything up to the venue — fee, share debits, the protocol redeem, credits — is production code.
 */
contract R79SovrynHandler is SovrynErc20Handler, PurchaseRbtc {
    uint256 public rbtcOut;

    constructor(address dcaManager, address stablecoin, address iSusd, FeeSettings memory feeSettings)
        SovrynErc20Handler(dcaManager, stablecoin, iSusd, address(0xFEE), feeSettings, msg.sender)
    {}

    function setRbtcOut(uint256 amount) external {
        rbtcOut = amount;
    }

    function _purchaseRbtc(uint256 stablecoinAmount, uint256) internal override returns (uint256) {
        require(i_stableToken.transfer(address(0xBEEF), stablecoinAmount));
        return rbtcOut;
    }
}

/**
 * @notice The same handler with today's per-row share debit (one read and one write per row), kept
 *         verbatim as the differential reference. `_measuredProtocolRedeem` is private upstream, so its
 *         body is copied too.
 */
contract R79LegacySovrynHandler is R79SovrynHandler {
    constructor(address dcaManager, address stablecoin, address iSusd, FeeSettings memory feeSettings)
        R79SovrynHandler(dcaManager, stablecoin, iSusd, feeSettings)
    {}

    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts)
        internal
        override(LendingErc20Handler, StablecoinSource)
        returns (uint256)
    {
        uint256 exchangeRate = _exchangeRate();
        uint256 totalSharesToRedeem;

        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            uint256 usersSharesToRedeem = _stablecoinToShares(purchaseAmounts[i], exchangeRate);
            uint256 usersShares = s_shares[users[i]];
            if (usersSharesToRedeem > usersShares) {
                revert TokenLending__InsufficientShares(users[i], usersSharesToRedeem, usersShares);
            }
            unchecked {
                s_shares[users[i]] = usersShares - usersSharesToRedeem;
            }
            if (usersSharesToRedeem != 0) {
                emit TokenLending__UserSharesUpdated(users[i], usersShares, usersShares - usersSharesToRedeem);
            }
            totalSharesToRedeem += usersSharesToRedeem;
        }
        uint256 stablecoinReceived = _legacyMeasuredProtocolRedeem(totalSharesToRedeem, exchangeRate);
        if (stablecoinReceived > 0) {
            emit TokenLending__SharesRedeemedBatch(stablecoinReceived, totalSharesToRedeem);
            return stablecoinReceived;
        }
        uint256 requested;
        for (uint256 i; i < numOfPurchases; ++i) {
            requested += purchaseAmounts[i];
        }
        revert TokenLending__ZeroStablecoinReceived(requested);
    }

    function _legacyMeasuredProtocolRedeem(uint256 sharesAmount, uint256 exchangeRate)
        private
        returns (uint256 received)
    {
        uint256 sharesBefore = _receiptSharesBalance();
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        _protocolRedeem(sharesAmount, exchangeRate);
        uint256 sharesAfter = _receiptSharesBalance();
        if (sharesAfter >= sharesBefore || sharesBefore - sharesAfter != sharesAmount) {
            revert TokenLending__ShareConsumptionMismatch(sharesAmount, sharesBefore, sharesAfter);
        }
        received = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
    }
}

/// @notice Idle handler whose venue takes the net stablecoin and reports a fixed rBTC figure.
contract R79IdleHandler is IdleErc20Handler, PurchaseRbtc {
    uint256 public rbtcOut;

    constructor(address dcaManager, address stablecoin, FeeSettings memory feeSettings)
        IdleErc20Handler(dcaManager, stablecoin, address(0xFEE), feeSettings, msg.sender)
    {}

    function setRbtcOut(uint256 amount) external {
        rbtcOut = amount;
    }

    function _purchaseRbtc(uint256 stablecoinAmount, uint256) internal override returns (uint256) {
        require(i_stableToken.transfer(address(0xBEEF), stablecoinAmount));
        return rbtcOut;
    }
}

/// @notice The same idle handler with today's per-row idle debit, kept verbatim as the reference.
contract R79LegacyIdleHandler is R79IdleHandler {
    constructor(address dcaManager, address stablecoin, FeeSettings memory feeSettings)
        R79IdleHandler(dcaManager, stablecoin, feeSettings)
    {}

    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts)
        internal
        override(IdleErc20Handler, StablecoinSource)
        returns (uint256 totalWithdrawn)
    {
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 idleBalance = s_idleBalances[users[i]];
            if (amount > idleBalance) {
                revert IdleErc20Handler__InsufficientIdleBalance(users[i], amount, idleBalance);
            }
            unchecked {
                s_idleBalances[users[i]] = idleBalance - amount;
            }
            totalWithdrawn += amount;
        }
    }
}

/**
 * @title R79CoalescedWritesDifferential
 * @notice R79 writes a repeated buyer's balance slots once per contiguous run instead of once per row.
 *         This suite proves that nothing else moved: on the same fuzzed state and rows, the shipped
 *         handler and a copy of today's per-row loop succeed or revert with the same data, emit the same
 *         logs in the same order, and leave the same balances. Accumulated rBTC has no legacy copy to run
 *         (the credit loop sits in `batchBuyRbtc`, which is not virtual), so its raw slot is checked
 *         against a per-row replay of today's credit rule over the emitted `RbtcBought` rows.
 * @dev Rows draw from a pool of three buyers, so single-buyer, clustered, and unsorted runs all occur.
 *      Reproduce with `forge test --match-path test/unit/R79CoalescedWritesDifferential.t.sol`, and the
 *      same with `FOUNDRY_PROFILE=deploy`.
 */
contract R79CoalescedWritesDifferentialTest is Test {
    uint256 internal constant POOL = 3;
    uint256 internal constant MAX_ROWS = 12;
    uint256 internal constant MIN_AMOUNT = 1e15;
    uint256 internal constant MAX_AMOUNT = 50 ether;
    uint256 internal constant MAX_DEPOSIT = 300 ether;

    MockStablecoin internal stablecoin;
    MockIsusdToken internal iSusd;
    R79SovrynHandler internal lending;
    R79LegacySovrynHandler internal legacyLending;
    R79IdleHandler internal idle;
    R79LegacyIdleHandler internal legacyIdle;
    address[POOL] internal pool = [address(0xA11CE), address(0xB0B), address(0xCA7)];

    function setUp() public {
        stablecoin = new MockStablecoin(address(this));
        iSusd = new MockIsusdToken(address(stablecoin));
        stablecoin.mint(address(iSusd), 1_000_000 ether);
        // A variable fee, so rows of different sizes pay different rates and rounding differs per row.
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: 100, maxFeeRate: 200, feePurchaseLowerBound: 1 ether, feePurchaseUpperBound: 40 ether
        });
        lending = new R79SovrynHandler(address(this), address(stablecoin), address(iSusd), feeSettings);
        legacyLending = new R79LegacySovrynHandler(address(this), address(stablecoin), address(iSusd), feeSettings);
        idle = new R79IdleHandler(address(this), address(stablecoin), feeSettings);
        legacyIdle = new R79LegacyIdleHandler(address(this), address(stablecoin), feeSettings);

        for (uint256 i; i < POOL; ++i) {
            stablecoin.mint(pool[i], 4 * MAX_DEPOSIT);
            vm.startPrank(pool[i]);
            stablecoin.approve(address(lending), type(uint256).max);
            stablecoin.approve(address(legacyLending), type(uint256).max);
            stablecoin.approve(address(idle), type(uint256).max);
            stablecoin.approve(address(legacyIdle), type(uint256).max);
            vm.stopPrank();
        }
        _assertSlotsMatchLayout();
    }

    function testFuzz_lendingBatchMatchesPerRowReference(
        uint256[POOL] memory deposits,
        uint8[POOL] memory rbtcStates,
        uint256 rowSeed,
        uint256 rows,
        uint256 rbtcOut,
        uint256 warp
    ) public {
        _prepare(address(lending), address(legacyLending), deposits, rbtcStates);
        vm.warp(block.timestamp + bound(warp, 0, 3 * 365 days));
        (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts) = _rows(rowSeed, rows);
        rbtcOut = bound(rbtcOut, 1, 10 ether);
        lending.setRbtcOut(rbtcOut);
        legacyLending.setRbtcOut(rbtcOut);

        _compare(address(lending), address(legacyLending), buyers, ids, amounts);
        for (uint256 i; i < POOL; ++i) {
            assertEq(lending.getUserShares(pool[i]), legacyLending.getUserShares(pool[i]), "shares differ");
        }
    }

    function testFuzz_idleBatchMatchesPerRowReference(
        uint256[POOL] memory deposits,
        uint8[POOL] memory rbtcStates,
        uint256 rowSeed,
        uint256 rows,
        uint256 rbtcOut
    ) public {
        _prepare(address(idle), address(legacyIdle), deposits, rbtcStates);
        (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts) = _rows(rowSeed, rows);
        rbtcOut = bound(rbtcOut, 1, 10 ether);
        idle.setRbtcOut(rbtcOut);
        legacyIdle.setRbtcOut(rbtcOut);

        _compare(address(idle), address(legacyIdle), buyers, ids, amounts);
        for (uint256 i; i < POOL; ++i) {
            assertEq(
                idle.getUsersIdleTokenBalance(pool[i]), legacyIdle.getUsersIdleTokenBalance(pool[i]), "idle differs"
            );
        }
    }

    /// @dev One buyer, five rows, tiny rBTC out: every row floors to zero, so a never-credited buyer stays `0`.
    function test_allZeroRunLeavesNeverCreditedBuyerAtZero() public {
        uint256[POOL] memory deposits = [MAX_DEPOSIT, uint256(0), uint256(0)];
        uint8[POOL] memory rbtcStates;
        _prepare(address(lending), address(legacyLending), deposits, rbtcStates);
        (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts) = _sameBuyerRows(pool[0], 5);
        lending.setRbtcOut(1);
        legacyLending.setRbtcOut(1);

        _compare(address(lending), address(legacyLending), buyers, ids, amounts);
        assertEq(uint256(vm.load(address(lending), R79Slots.key(pool[0], R79Slots.ACCUMULATED_RBTC))), 0);
    }

    /// @dev The third row of one run overdraws: the error must carry the running balance, not the stored one.
    function test_overdrawMidRunRevertsWithRunningBalance() public {
        uint256[POOL] memory deposits = [uint256(25 ether), uint256(0), uint256(0)];
        uint8[POOL] memory rbtcStates;
        _prepare(address(idle), address(legacyIdle), deposits, rbtcStates);
        (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts) = _sameBuyerRows(pool[0], 3);
        for (uint256 i; i < 3; ++i) {
            amounts[i] = 10 ether;
        }
        idle.setRbtcOut(1 ether);
        legacyIdle.setRbtcOut(1 ether);

        vm.expectRevert(
            abi.encodeWithSignature(
                "IdleErc20Handler__InsufficientIdleBalance(address,uint256,uint256)", pool[0], 10 ether, 5 ether
            )
        );
        idle.batchBuyRbtc(buyers, ids, amounts, 0);
        _compare(address(idle), address(legacyIdle), buyers, ids, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deposit the same amount for each pool buyer on both handlers, then put both handlers' rBTC slot
     *      for that buyer in the same state: never credited (`0`), post-withdraw sentinel (`1`), or live.
     */
    function _prepare(
        address subject,
        address reference_,
        uint256[POOL] memory deposits,
        uint8[POOL] memory rbtcStates
    ) private {
        for (uint256 i; i < POOL; ++i) {
            uint256 deposit = bound(deposits[i], 0, MAX_DEPOSIT);
            if (deposit != 0) {
                ITokenHandler(subject).depositToken(pool[i], deposit);
                ITokenHandler(reference_).depositToken(pool[i], deposit);
            }
            uint256 state = rbtcStates[i] % 3;
            uint256 encoded = state == 0 ? 0 : state == 1 ? 1 : 1 + 0.5 ether + uint256(rbtcStates[i]);
            vm.store(subject, R79Slots.key(pool[i], R79Slots.ACCUMULATED_RBTC), bytes32(encoded));
            vm.store(reference_, R79Slots.key(pool[i], R79Slots.ACCUMULATED_RBTC), bytes32(encoded));
        }
    }

    function _rows(uint256 rowSeed, uint256 rows)
        private
        view
        returns (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts)
    {
        rows = bound(rows, 1, MAX_ROWS);
        buyers = new address[](rows);
        ids = new uint64[](rows);
        amounts = new uint256[](rows);
        for (uint256 i; i < rows; ++i) {
            uint256 draw = uint256(keccak256(abi.encode(rowSeed, i)));
            buyers[i] = pool[draw % POOL];
            ids[i] = uint64(i + 1);
            amounts[i] = bound(draw >> 8, MIN_AMOUNT, MAX_AMOUNT);
        }
    }

    function _sameBuyerRows(address buyer, uint256 rows)
        private
        pure
        returns (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts)
    {
        buyers = new address[](rows);
        ids = new uint64[](rows);
        amounts = new uint256[](rows);
        for (uint256 i; i < rows; ++i) {
            buyers[i] = buyer;
            ids[i] = uint64(i + 1);
            amounts[i] = 20 ether;
        }
    }

    /**
     * @dev Run the reference, then the subject, on the same rows. Both must succeed or both must revert with
     *      the same data. On success their own logs must match one for one, and each buyer's raw rBTC slot on
     *      the subject must equal a per-row replay of today's credit rule over the subject's `RbtcBought` logs.
     */
    function _compare(
        address subject,
        address reference_,
        address[] memory buyers,
        uint64[] memory ids,
        uint256[] memory amounts
    ) private {
        uint256[POOL] memory encodedBefore;
        for (uint256 i; i < POOL; ++i) {
            encodedBefore[i] = uint256(vm.load(subject, R79Slots.key(pool[i], R79Slots.ACCUMULATED_RBTC)));
        }
        bytes memory call = abi.encodeCall(IPurchaseRbtc.batchBuyRbtc, (buyers, ids, amounts, 0));

        vm.recordLogs();
        (bool referenceOk, bytes memory referenceData) = reference_.call(call);
        Vm.Log[] memory referenceLogs = _logsOf(reference_, vm.getRecordedLogs());

        vm.recordLogs();
        (bool subjectOk, bytes memory subjectData) = subject.call(call);
        Vm.Log[] memory subjectLogs = _logsOf(subject, vm.getRecordedLogs());

        assertEq(subjectOk, referenceOk, "one variant reverted");
        assertEq(subjectData, referenceData, "return or revert data differs");
        if (!subjectOk) return;

        assertEq(subjectLogs.length, referenceLogs.length, "log count differs");
        for (uint256 i; i < subjectLogs.length; ++i) {
            assertEq(abi.encode(subjectLogs[i].topics), abi.encode(referenceLogs[i].topics), "log topics differ");
            assertEq(subjectLogs[i].data, referenceLogs[i].data, "log data differs");
        }
        _assertRbtcMatchesPerRowReplay(subject, subjectLogs, encodedBefore);
    }

    function _assertRbtcMatchesPerRowReplay(address subject, Vm.Log[] memory logs, uint256[POOL] memory encoded)
        private
    {
        bytes32 rbtcBought = IPurchaseRbtc.PurchaseRbtc__RbtcBought.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != rbtcBought) continue;
            address buyer = address(uint160(uint256(logs[i].topics[1])));
            (uint256 amount,) = abi.decode(logs[i].data, (uint256, uint256));
            if (amount == 0) continue;
            uint256 p = _poolIndex(buyer);
            encoded[p] = (encoded[p] == 0 ? 1 : encoded[p]) + amount;
        }
        for (uint256 i; i < POOL; ++i) {
            assertEq(
                uint256(vm.load(subject, R79Slots.key(pool[i], R79Slots.ACCUMULATED_RBTC))),
                encoded[i],
                "rBTC slot differs from per-row replay"
            );
        }
    }

    function _logsOf(address emitter, Vm.Log[] memory all) private pure returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == emitter) ++n;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == emitter) out[n++] = all[i];
        }
    }

    function _poolIndex(address buyer) private view returns (uint256) {
        for (uint256 i; i < POOL; ++i) {
            if (pool[i] == buyer) return i;
        }
        revert("buyer outside pool");
    }

    /// @dev Pin the hardcoded slots to the live layout through public getters.
    function _assertSlotsMatchLayout() private {
        uint256 snap = vm.snapshot();
        lending.depositToken(pool[0], 1 ether);
        assertEq(uint256(vm.load(address(lending), R79Slots.key(pool[0], R79Slots.SHARES))), lending.getUserShares(pool[0]));
        idle.depositToken(pool[0], 1 ether);
        assertEq(
            uint256(vm.load(address(idle), R79Slots.key(pool[0], R79Slots.IDLE_BALANCES))),
            idle.getUsersIdleTokenBalance(pool[0])
        );
        vm.store(address(lending), R79Slots.key(pool[0], R79Slots.ACCUMULATED_RBTC), bytes32(uint256(7)));
        vm.store(address(idle), R79Slots.key(pool[0], R79Slots.ACCUMULATED_RBTC), bytes32(uint256(7)));
        assertEq(lending.getAccumulatedRbtcBalance(pool[0]), 6);
        assertEq(idle.getAccumulatedRbtcBalance(pool[0]), 6);
        vm.revertTo(snap);
    }
}
