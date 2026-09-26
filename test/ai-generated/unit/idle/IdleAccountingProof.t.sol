// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import "test/Constants.sol";
import {batchBuyOne} from "test/utils/BatchBuyOne.sol";
import {scheduleAt, scheduleIdAt, scheduleCount} from "test/utils/ScheduleAt.sol";

/**
 * @title IdleAccountingProof
 * @notice R87 gate: without a per-user idle ledger, schedule liabilities stay solvent against handler
 *         cash, enumerate correctly by creation id, and do not cross-contaminate users.
 * @dev Coverage counters must all be non-zero before the solvency assertions run, so a suite that
 *      never exercised a transition cannot vacuous-pass.
 */
contract IdleAccountingProofTest is Test {
    address internal constant OWNER = address(0x1111);
    address internal constant SWAPPER = address(0x3333);
    address internal constant FEE_COLLECTOR = address(0x5555);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    uint256 internal constant DEPOSIT = 200 ether;
    uint256 internal constant PURCHASE = 50 ether;
    uint256 internal constant TOP_UP = 40 ether;
    uint256 internal constant WITHDRAW = 30 ether;

    DcaManager internal dcaManager;
    OperationsAdmin internal operationsAdmin;
    MockStablecoin internal doc;
    MockMocProxy internal moc;
    IdleDocHandlerMoc internal handler;

    uint256 internal creates;
    uint256 internal deposits;
    uint256 internal purchases;
    uint256 internal withdrawals;
    uint256 internal deletions;

    mapping(address user => uint256 liability) internal ghostLiability;
    /// @dev Enumeration proof phases: 0 untouched, 1 live under creation-id scan, 2 seen once in a user list.
    mapping(uint64 scheduleId => uint8 phase) internal enumPhase;

    function setUp() public {
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin(OWNER);

        vm.prank(OWNER);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, OWNER);

        doc = new MockStablecoin(address(this));
        moc = new MockMocProxy(address(doc));
        vm.deal(address(moc), 1_000 ether);

        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
        handler = new IdleDocHandlerMoc(
            address(dcaManager), address(doc), FEE_COLLECTOR, address(moc), feeSettings, OWNER
        );

        vm.startPrank(OWNER);
        operationsAdmin.addSwapper(SWAPPER);
        operationsAdmin.assignTokenHandler(address(doc), IDLE_INDEX, address(handler));
        dcaManager.setTokenMinPurchaseAmount(address(doc), MIN_PURCHASE_AMOUNT);
        vm.stopPrank();

        vm.prank(address(handler));
        doc.approve(address(moc), type(uint256).max);

        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
    }

    /// @notice Walk every liability-changing transition, then assert the five R87 proof obligations.
    function test_idleAccounting_allTransitionsProveGhostSolvencyAndIsolation() public {
        uint64 aliceId = _create(ALICE, DEPOSIT);
        uint64 bobId = _create(BOB, DEPOSIT);
        uint256 bobLiabilityAfterCreate = ghostLiability[BOB];

        _deposit(ALICE, aliceId, TOP_UP);
        assertEq(ghostLiability[BOB], bobLiabilityAfterCreate, "Alice deposit changed Bob");

        uint256 bobLiabilityAfterDeposit = ghostLiability[BOB];
        _purchase(aliceId);
        assertEq(ghostLiability[BOB], bobLiabilityAfterDeposit, "Alice purchase changed Bob");

        uint256 bobLiabilityAfterPurchase = ghostLiability[BOB];
        _withdraw(ALICE, aliceId, WITHDRAW);
        assertEq(ghostLiability[BOB], bobLiabilityAfterPurchase, "Alice withdraw changed Bob");

        uint256 aliceLiabilityBeforeDelete = ghostLiability[ALICE];
        _delete(BOB, bobId);
        assertEq(ghostLiability[ALICE], aliceLiabilityBeforeDelete, "Bob delete changed Alice");
        assertEq(ghostLiability[BOB], 0);
        assertEq(ghostLiability[CAROL], 0);

        _assertCoverage();
        _assertPerUserGhostMatchesSchedules();
        _assertAggregateSolvency();
        _assertCreationIdEnumeration();
    }

    /// @notice Fuzzed multi-user create/deposit/purchase/withdraw/delete keeps the same invariants.
    function testFuzz_idleAccounting_randomTransitionSequence(uint256 seed) public {
        address[3] memory users = [ALICE, BOB, CAROL];
        uint64[3] memory liveIds;
        bool[3] memory hasSchedule;

        uint256 steps = bound(seed, 8, 24);
        for (uint256 i; i < steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 actor = seed % 3;
            address user = users[actor];
            uint256 action = (seed >> 8) % 5;

            if (action == 0 || !hasSchedule[actor]) {
                if (scheduleCount(dcaManager, user, address(doc)) >= MAX_SCHEDULES_PER_TOKEN) continue;
                liveIds[actor] = _create(user, DEPOSIT);
                hasSchedule[actor] = true;
                continue;
            }

            uint64 scheduleId = liveIds[actor];
            (bool ok, IDcaManager.DcaSchedule memory schedule) = _tryGetSchedule(scheduleId);
            if (!ok || schedule.user != user) {
                hasSchedule[actor] = false;
                continue;
            }

            if (action == 1) {
                _deposit(user, scheduleId, TOP_UP);
            } else if (action == 2) {
                if (schedule.tokenBalance < schedule.purchaseAmount) continue;
                if (schedule.cadenceAnchor != 0) {
                    vm.warp(uint256(schedule.cadenceAnchor) + uint256(schedule.purchasePeriod) + 1);
                }
                _purchase(scheduleId);
            } else if (action == 3) {
                uint256 bal = schedule.tokenBalance;
                if (bal == 0) continue;
                uint256 amount = bound(seed >> 16, 1, bal);
                _withdraw(user, scheduleId, amount);
            } else {
                _delete(user, scheduleId);
                hasSchedule[actor] = false;
            }
        }

        // Force any missing transition once so coverage cannot stay zero after a lucky seed.
        if (scheduleCount(dcaManager, ALICE, address(doc)) == 0) {
            liveIds[0] = _create(ALICE, DEPOSIT);
            hasSchedule[0] = true;
        } else if (!hasSchedule[0]) {
            liveIds[0] = scheduleIdAt(dcaManager, ALICE, address(doc), 0);
            hasSchedule[0] = true;
        }
        uint64 aliceId = liveIds[0];
        // Re-validate: the tracked id may have been deleted under another actor seed path.
        (bool aliceOk,) = _tryGetSchedule(aliceId);
        if (!aliceOk) {
            if (scheduleCount(dcaManager, ALICE, address(doc)) == 0) {
                aliceId = _create(ALICE, DEPOSIT);
            } else {
                aliceId = scheduleIdAt(dcaManager, ALICE, address(doc), 0);
            }
            liveIds[0] = aliceId;
            hasSchedule[0] = true;
        }
        if (deposits == 0) _deposit(ALICE, aliceId, TOP_UP);
        if (purchases == 0) {
            IDcaManager.DcaSchedule memory s = dcaManager.getDcaSchedule(address(doc), aliceId);
            if (s.tokenBalance < s.purchaseAmount) _deposit(ALICE, aliceId, PURCHASE);
            s = dcaManager.getDcaSchedule(address(doc), aliceId);
            if (s.cadenceAnchor != 0) {
                vm.warp(uint256(s.cadenceAnchor) + uint256(s.purchasePeriod) + 1);
            }
            _purchase(aliceId);
        }
        if (withdrawals == 0) {
            IDcaManager.DcaSchedule memory s = dcaManager.getDcaSchedule(address(doc), aliceId);
            if (s.tokenBalance == 0) _deposit(ALICE, aliceId, WITHDRAW);
            _withdraw(ALICE, aliceId, 1);
        }
        if (deletions == 0) {
            if (scheduleCount(dcaManager, BOB, address(doc)) >= MAX_SCHEDULES_PER_TOKEN) {
                uint64 existing = scheduleIdAt(dcaManager, BOB, address(doc), 0);
                _delete(BOB, existing);
            } else {
                uint64 id = _create(BOB, DEPOSIT);
                _delete(BOB, id);
            }
        }

        _assertCoverage();
        _assertPerUserGhostMatchesSchedules();
        _assertAggregateSolvency();
        _assertCreationIdEnumeration();
    }

    /*//////////////////////////////////////////////////////////////
                              ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    function _assertCoverage() private {
        assertGt(creates, 0, "create never ran");
        assertGt(deposits, 0, "deposit never ran");
        assertGt(purchases, 0, "purchase never ran");
        assertGt(withdrawals, 0, "withdraw never ran");
        assertGt(deletions, 0, "delete never ran");
    }

    function _assertPerUserGhostMatchesSchedules() private {
        address[3] memory users = [ALICE, BOB, CAROL];
        for (uint256 i; i < users.length; ++i) {
            assertEq(ghostLiability[users[i]], _sumUserIdleSchedules(users[i]), "ghost != schedule sum");
        }
    }

    function _assertAggregateSolvency() private {
        uint256 totalLiability = ghostLiability[ALICE] + ghostLiability[BOB] + ghostLiability[CAROL];
        assertEq(totalLiability, _totalIdleLiability(), "ghost aggregate != creation-id sum");
        assertEq(doc.balanceOf(address(handler)), totalLiability, "handler cash != sum of idle liabilities");
    }

    function _assertCreationIdEnumeration() private {
        uint64 nonce = uint64(dcaManager.getSchedulesCreatedCount());
        address[3] memory users = [ALICE, BOB, CAROL];

        for (uint64 id = 1; id <= nonce; ++id) {
            enumPhase[id] = 0;
        }

        uint256 liveCount;
        for (uint64 id = 1; id <= nonce; ++id) {
            (bool ok, IDcaManager.DcaSchedule memory schedule) = _tryGetSchedule(id);
            if (!ok) continue;
            assertEq(schedule.routeIndex, IDLE_INDEX, "live schedule not on idle route");
            bool ownerKnown;
            for (uint256 i; i < users.length; ++i) {
                if (schedule.user == users[i]) {
                    ownerKnown = true;
                    break;
                }
            }
            assertTrue(ownerKnown, "live schedule owner not in the actor set");
            enumPhase[id] = 1;
            ++liveCount;
        }

        uint256 enumerated;
        for (uint256 i; i < users.length; ++i) {
            (uint64[] memory ids,) = dcaManager.getDcaSchedules(users[i], address(doc));
            for (uint256 j; j < ids.length; ++j) {
                uint64 id = ids[j];
                assertEq(enumPhase[id], 1, "enumerated id missing from creation scan or duplicated");
                enumPhase[id] = 2;
                IDcaManager.DcaSchedule memory s = dcaManager.getDcaSchedule(address(doc), id);
                assertEq(s.user, users[i], "enumeration owner mismatch");
                assertEq(s.routeIndex, IDLE_INDEX);
                ++enumerated;
            }
        }
        assertEq(enumerated, liveCount, "creation-id scan disagreed with per-user lists");

        for (uint64 id = 1; id <= nonce; ++id) {
            uint8 phase = enumPhase[id];
            if (phase == 0) continue; // deleted / never assigned
            assertEq(phase, 2, "live creation id not enumerated exactly once");
        }
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    function _create(address user, uint256 depositAmount) private returns (uint64 scheduleId) {
        uint256 beforeCount = scheduleCount(dcaManager, user, address(doc));
        vm.prank(user);
        dcaManager.createDcaSchedule(address(doc), depositAmount, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        scheduleId = scheduleIdAt(dcaManager, user, address(doc), beforeCount);
        ghostLiability[user] += depositAmount;
        ++creates;
    }

    function _deposit(address user, uint64 scheduleId, uint256 amount) private {
        vm.prank(user);
        dcaManager.depositToken(address(doc), scheduleId, amount);
        ghostLiability[user] += amount;
        ++deposits;
    }

    function _purchase(uint64 scheduleId) private {
        IDcaManager.DcaSchedule memory before = dcaManager.getDcaSchedule(address(doc), scheduleId);
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, address(doc), scheduleId, IDLE_INDEX);
        ghostLiability[before.user] -= before.purchaseAmount;
        ++purchases;
    }

    function _withdraw(address user, uint64 scheduleId, uint256 amount) private {
        vm.prank(user);
        dcaManager.withdrawToken(address(doc), scheduleId, amount);
        ghostLiability[user] -= amount;
        ++withdrawals;
    }

    function _delete(address user, uint64 scheduleId) private {
        IDcaManager.DcaSchedule memory before = dcaManager.getDcaSchedule(address(doc), scheduleId);
        (uint64[] memory ids,) = dcaManager.getDcaSchedules(user, address(doc));
        uint256 index = type(uint256).max;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == scheduleId) {
                index = i;
                break;
            }
        }
        require(index != type(uint256).max, "schedule id not in caller list");
        vm.prank(user);
        dcaManager.deleteDcaSchedule(address(doc), scheduleId, index);
        ghostLiability[user] -= before.tokenBalance;
        ++deletions;
    }

    /*//////////////////////////////////////////////////////////////
                                GHOSTS
    //////////////////////////////////////////////////////////////*/

    function _sumUserIdleSchedules(address user) private view returns (uint256 sum) {
        (, IDcaManager.DcaSchedule[] memory schedules) = dcaManager.getDcaSchedules(user, address(doc));
        for (uint256 i; i < schedules.length; ++i) {
            if (schedules[i].routeIndex == IDLE_INDEX) {
                sum += schedules[i].tokenBalance;
            }
        }
    }

    function _totalIdleLiability() private returns (uint256 sum) {
        uint64 nonce = uint64(dcaManager.getSchedulesCreatedCount());
        for (uint64 id = 1; id <= nonce; ++id) {
            (bool ok, IDcaManager.DcaSchedule memory schedule) = _tryGetSchedule(id);
            if (!ok) continue;
            if (schedule.routeIndex != IDLE_INDEX) continue;
            sum += schedule.tokenBalance;
        }
    }

    function _tryGetSchedule(uint64 id) private returns (bool ok, IDcaManager.DcaSchedule memory schedule) {
        try dcaManager.getDcaSchedule(address(doc), id) returns (IDcaManager.DcaSchedule memory s) {
            return (true, s);
        } catch {
            return (false, schedule);
        }
    }

    function _fund(address user) private {
        doc.mint(user, 1_000_000 ether);
        vm.prank(user);
        doc.approve(address(handler), type(uint256).max);
    }
}
