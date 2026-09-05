// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {StubPurchaseHandler} from "./StubPurchaseHandler.sol";
import {NestedIndexedDcaManager} from "./prototype/NestedIndexedDcaManager.sol";
import {FlatKeyedDcaManager} from "./prototype/FlatKeyedDcaManager.sol";
import {UserKeyedDcaManager} from "./prototype/UserKeyedDcaManager.sol";
import {TokenKeyedDcaManager} from "./prototype/TokenKeyedDcaManager.sol";
import {RouteIdDcaManager} from "./prototype/RouteIdDcaManager.sol";
import {RouteIdRegistry} from "./prototype/RouteIdRegistry.sol";
import {TripleKeyedDcaManager} from "./prototype/TripleKeyedDcaManager.sol";
import {PackedRowDcaManager} from "./prototype/PackedRowDcaManager.sol";
import {UserTokenIdDcaManager} from "./prototype/UserTokenIdDcaManager.sol";

/**
 * @title R64BatchGasBenchmark
 * @notice Prices the schedule-key and batch-calldata designs considered for R64 on the path the
 *         swapper pays every day.
 * @dev Reproduce the table with:
 *
 *          forge test --match-path 'test/gas/*' -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path 'test/gas/*' -vv
 *
 *      Nine designs, identical schedules, one stub handler per design and size. The sizes are 1, 5,
 *      10, 50 and 200 rows; 5 is there because the last tick the live protocol ran before this branch
 *      was a five-schedule batch, so the table can be read against a transaction that happened.
 *        A — `src/DcaManager`: keyed by `(token, scheduleId)`, with the owner stored and checked, and
 *            a batch row that is one id.
 *        B — pre-R64: keyed by `(user, token, index)`, with ids, buyers, indexes, and amounts.
 *        C — keyed by `scheduleId`, with owner and token stored in a three-slot value.
 *        D — A with the per-row purchase-amount staleness guard restored.
 *        E — A's design with the mapping's keys the other way round, `(scheduleId, token)`. Same work,
 *            same storage, one difference: with the token innermost its hash is recomputed per row,
 *            while A's outermost token hashes once for the whole batch.
 *        F — keyed by `scheduleId` alone, the schedule carrying a `uint32 routeId` in place of the
 *            token address, so a flat key still fits two slots.
 *        G — keyed by `(scheduleId, user, token)`: both halves of a schedule's identity in the key, so
 *            no identity is stored and none is checked. `purchaseAmount` keeps its full `uint128`.
 *        H — G's key with the batch row packed as `(scheduleId << 160) | buyer`, one word per row.
 *        I — keyed by `(user, token, scheduleId)`: the pre-R64 key with the index replaced by the id.
 *
 *      One difference the table does not isolate: every prototype reads its schedule by copying the
 *      struct into memory, the way `src/DcaManager` did until late in this branch, while A now reads
 *      through a storage pointer — worth about 430 gas a row under via-IR. That is faithful for B,
 *      which reproduces the pre-R64 contract as it was, and it is a handicap on every other row when
 *      one design is compared with A. The spec's `Reading a schedule` section has the measurement.
 *
 *      What each column means:
 *        `calldata`  Intrinsic transaction cost of the encoded call. Computed from the bytes actually
 *                    sent, on Rootstock's schedule (see `_intrinsicCalldataGas`). A test calling a
 *                    contract never pays this — a swapper sending a transaction always does, so it has
 *                    to be added back by hand or the whole comparison misses the point.
 *        `exec`      Gas the call itself burned, measured around a raw `call` with those same bytes.
 *        `handler`   The stub handler leg inside `exec`, measured separately at the same length. It is
 *                    identical across designs by construction; a real venue's cost is far larger and
 *                    equally identical, which is exactly why it is held out of the comparison.
 *        `manager`   `exec - handler`: the schedule bookkeeping, which is what the design changes.
 *        `total`     `calldata + exec`, the operator's bill for the batch.
 *
 *      Registry access is measured, not held out. Every (design, size) pair gets its own token, its own
 *      handler and its own route record, so each measured batch reads a registry slot that is cold, as
 *      the first batch of a real transaction does. That matters because the designs do not read the
 *      same number of slots: A through E resolve a handler in one, while F reads a second for the
 *      stablecoin its events name. An earlier version of this file warmed the registry for every design
 *      before measuring, which silently handed F that second slot for free — and because the whole
 *      benchmark is one transaction, F's first batch then left it warm for every size that followed.
 *      Only the swapper allowlist and the handler accounts are pre-warmed, and those are identical work
 *      for every design.
 */
contract R64BatchGasBenchmarkTest is Test {
    uint256 private constant MAX_SCHEDULES_PER_TOKEN = 5;
    uint256 private constant MIN_PURCHASE_PERIOD = 1 days;
    uint256 private constant MIN_PURCHASE_AMOUNT = 1e18;
    uint256 private constant DEPOSIT_AMOUNT = 1000e18;
    uint256 private constant PURCHASE_AMOUNT = 10e18;
    uint256 private constant PURCHASE_PERIOD = 1 days;
    uint256 private constant ROUTE_INDEX = 0;
    uint256 private constant START_TIMESTAMP = 1_770_000_000; // 2026-02-02, a plausible relaunch clock

    uint256 private constant DESIGNS = 9;
    uint256 private constant SIZES = 5;

    /// @dev Batch sizes the spec asks for.
    uint256[SIZES] private s_batchSizes = [uint256(1), 5, 10, 50, 200];
    /// @dev Schedule 0 is never batched; it exists so the size groups start at a non-zero offset.
    uint256 private constant FIRST_SCHEDULE = 1;
    uint256 private constant TOTAL_SCHEDULES = 266; // 1 + 5 + 10 + 50 + 200

    address private s_swapper;

    OperationsAdmin private s_operationsAdmin;
    RouteIdRegistry private s_routeIdRegistry;

    DcaManager private s_designA;
    NestedIndexedDcaManager private s_designB;
    FlatKeyedDcaManager private s_designC;
    UserKeyedDcaManager private s_designD;
    TokenKeyedDcaManager private s_designE;
    RouteIdDcaManager private s_designF;
    TripleKeyedDcaManager private s_designG;
    PackedRowDcaManager private s_designH;
    UserTokenIdDcaManager private s_designI;

    /// @dev One per design, indexed by design number, so the loops do not branch on it.
    address[DESIGNS] private s_managers;
    /// @dev One token, handler and route record per (design, size), so every measured batch reads a
    ///      cold registry slot rather than one a previous size already paid for.
    address[SIZES][DESIGNS] private s_tokens;
    StubPurchaseHandler[SIZES][DESIGNS] private s_handlers;
    uint32[SIZES] private s_routeIdsF;

    /// @dev Buyer `i` owns schedule `i` on every design; ids run 1..267 in the same order on all nine.
    address[] private s_buyers;

    function setUp() public {
        vm.warp(START_TIMESTAMP);
        s_swapper = makeAddr("swapper");

        s_operationsAdmin = new OperationsAdmin(address(this));
        s_operationsAdmin.addSwapper(s_swapper);
        s_routeIdRegistry = new RouteIdRegistry();
        s_routeIdRegistry.addSwapper(s_swapper);

        s_designA = new DcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, address(this)
        );
        s_designB = new NestedIndexedDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designC = new FlatKeyedDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designD = new UserKeyedDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designE = new TokenKeyedDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designF = new RouteIdDcaManager(
            address(s_routeIdRegistry), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designG = new TripleKeyedDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designH = new PackedRowDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designI = new UserTokenIdDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_managers = [
            address(s_designA),
            address(s_designB),
            address(s_designC),
            address(s_designD),
            address(s_designE),
            address(s_designF),
            address(s_designG),
            address(s_designH),
            address(s_designI)
        ];

        for (uint256 d; d < DESIGNS; ++d) {
            for (uint256 s; s < SIZES; ++s) {
                address token = address(uint160(uint256(keccak256(abi.encode("R64.token", d, s)))));
                s_tokens[d][s] = token;
                s_handlers[d][s] = new StubPurchaseHandler();
                if (d == 5) s_routeIdsF[s] = s_routeIdRegistry.assignTokenHandler(token, uint32(ROUTE_INDEX), address(s_handlers[d][s]));
                else s_operationsAdmin.assignTokenHandler(token, ROUTE_INDEX, address(s_handlers[d][s]));
            }
        }

        for (uint256 i; i < TOTAL_SCHEDULES + FIRST_SCHEDULE; ++i) {
            s_buyers.push(address(uint160(uint256(keccak256(abi.encode("R64.buyer", i))))));
            uint256 group = _groupOf(i);
            vm.startPrank(s_buyers[i]);
            s_designA.createDcaSchedule(s_tokens[0][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designB.createDcaSchedule(s_tokens[1][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designC.createDcaSchedule(s_tokens[2][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designD.createDcaSchedule(s_tokens[3][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designE.createDcaSchedule(s_tokens[4][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designF.createDcaSchedule(s_tokens[5][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designG.createDcaSchedule(s_tokens[6][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designH.createDcaSchedule(s_tokens[7][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designI.createDcaSchedule(s_tokens[8][group], DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            vm.stopPrank();
        }

        // One purchase over every schedule, so the measured tick is a steady-state one rather than a
        // first purchase, which takes a different branch and writes a zero timestamp.
        for (uint256 d; d < DESIGNS; ++d) {
            for (uint256 s; s < SIZES; ++s) {
                _buy(d, s);
            }
        }
        vm.warp(START_TIMESTAMP + 2 days);
    }

    /*//////////////////////////////////////////////////////////////
                              BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function test_r64_batchGasByDesign() public {
        console.log("");
        console.log("R64 batchBuyRbtc, steady-state tick, gas");
        console.log("design  rows   bytes  calldata      exec   handler   manager     total   per-row");

        for (uint256 d; d < DESIGNS; ++d) {
            for (uint256 s; s < SIZES; ++s) {
                _report(d, s);
            }
            console.log("");
        }
    }

    function test_r64_createAndDeleteGas() public {
        console.log("");
        console.log("R64 cold paths, gas (one schedule, paid by the user)");
        console.log("design    create    delete");

        _warmSharedState();

        address user = makeAddr("coldPathUser");
        uint256[DESIGNS] memory createGas;
        uint256[DESIGNS] memory deleteGas;

        vm.startPrank(user);
        for (uint256 d; d < DESIGNS; ++d) {
            (createGas[d], deleteGas[d]) = _coldPathGas(d, user);
        }
        vm.stopPrank();

        for (uint256 d; d < DESIGNS; ++d) {
            console.log(string.concat(_designName(d), "      ", _pad(createGas[d], 9), _pad(deleteGas[d], 10)));
        }
        console.log("");

        // Design B is the keying `DcaManager` had before R64, and holding the prototype to the figures
        // the real contract produced is what keeps it a baseline rather than a sketch: if it drifts from
        // the design it claims to reproduce, the run fails instead of quietly flattering the change.
        //
        // The create figure is 99,000 rather than the 91,622 first recorded for the real contract because
        // this file no longer pre-warms route records: a create now pays the cold registry read a first
        // transaction really pays, which is worth about 8,300. The delete path reads no route record and
        // is unchanged. The band is 10% because this assertion has to hold under both profiles and via-IR
        // takes about 6% off a cold path; a keying change moves these by ~50%, which is the drift it
        // exists to catch.
        assertApproxEqRel(createGas[1], 99_000, 0.10e18, "prototype B no longer reproduces the pre-R64 create");
        assertApproxEqRel(deleteGas[1], 11_122, 0.10e18, "prototype B no longer reproduces the pre-R64 delete");
    }

    /// @dev One create and one delete on `design`, as the same fresh user, measured separately.
    function _coldPathGas(uint256 design, address user) private returns (uint256 createGas, uint256 deleteGas) {
        address token = s_tokens[design][0];

        createGas = gasleft();
        if (design == 0) s_designA.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 1) s_designB.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 2) s_designC.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 3) s_designD.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 4) s_designE.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 5) s_designF.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 6) s_designG.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 7) s_designH.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else s_designI.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        createGas -= gasleft();

        uint64 scheduleId = _lastCreatedId(design, user, token);

        deleteGas = gasleft();
        if (design == 0) s_designA.deleteDcaSchedule(token, scheduleId);
        else if (design == 1) s_designB.deleteDcaSchedule(token, 0, scheduleId);
        else if (design == 2) s_designC.deleteDcaSchedule(scheduleId);
        else if (design == 3) s_designD.deleteDcaSchedule(scheduleId);
        else if (design == 4) s_designE.deleteDcaSchedule(token, scheduleId);
        else if (design == 5) s_designF.deleteDcaSchedule(scheduleId);
        else if (design == 6) s_designG.deleteDcaSchedule(token, scheduleId);
        else if (design == 7) s_designH.deleteDcaSchedule(token, scheduleId);
        else s_designI.deleteDcaSchedule(token, scheduleId);
        deleteGas -= gasleft();
    }

    function _lastCreatedId(uint256 design, address user, address token) private view returns (uint64) {
        if (design == 0) return scheduleIdAt(s_designA, user, token, 0);
        if (design == 1) return s_designB.getDcaSchedules(user, token)[0].scheduleId;
        if (design == 2) return uint64(s_designC.getSchedulesCreatedCount());
        if (design == 3) return uint64(s_designD.getSchedulesCreatedCount());
        if (design == 4) return uint64(s_designE.getSchedulesCreatedCount());
        if (design == 5) return uint64(s_designF.getSchedulesCreatedCount());
        if (design == 6) return uint64(s_designG.getSchedulesCreatedCount());
        if (design == 7) return uint64(s_designH.getSchedulesCreatedCount());
        return uint64(s_designI.getSchedulesCreatedCount());
    }

    /*//////////////////////////////////////////////////////////////
                             SANITY CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every design must debit the same schedules by the same amount, or the gas table is
    ///      comparing different work. Asserted rather than assumed.
    function test_r64_designsAgreeOnEffects() public {
        uint256 group = 1; // the ten-row group
        uint256 offset = _offsetOf(group);
        uint64 scheduleId = uint64(offset + 1);
        address buyer = s_buyers[offset];

        uint256 balanceBefore = scheduleAt(s_designA, buyer, s_tokens[0][group], 0).tokenBalance;
        assertEq(s_designF.getSchedule(scheduleId).tokenBalance, balanceBefore, "designs disagree before");

        for (uint256 d; d < DESIGNS; ++d) {
            _buy(d, group);
        }

        uint256 expected = balanceBefore - PURCHASE_AMOUNT;
        assertEq(scheduleAt(s_designA, buyer, s_tokens[0][group], 0).tokenBalance, expected, "A debited wrongly");
        assertEq(
            s_designB.getDcaSchedules(buyer, s_tokens[1][group])[0].tokenBalance, expected, "B debited wrongly"
        );
        assertEq(s_designC.getSchedule(scheduleId).tokenBalance, expected, "C debited wrongly");
        assertEq(s_designD.getSchedule(scheduleId, buyer).tokenBalance, expected, "D debited wrongly");
        assertEq(s_designE.getSchedule(scheduleId, s_tokens[4][group]).tokenBalance, expected, "E debited wrongly");
        assertEq(s_designF.getSchedule(scheduleId).tokenBalance, expected, "F debited wrongly");
        assertEq(
            s_designG.getSchedule(scheduleId, buyer, s_tokens[6][group]).tokenBalance, expected, "G debited wrongly"
        );
        assertEq(
            s_designH.getSchedule(scheduleId, buyer, s_tokens[7][group]).tokenBalance, expected, "H debited wrongly"
        );
        assertEq(
            s_designI.getSchedule(buyer, s_tokens[8][group], scheduleId).tokenBalance, expected, "I debited wrongly"
        );

        for (uint256 d = 1; d < DESIGNS; ++d) {
            assertEq(
                s_handlers[d][group].rowsBought(), s_handlers[0][group].rowsBought(), "designs bought a different row count"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _report(uint256 design, uint256 size) private {
        uint256 rows = s_batchSizes[size];
        bytes memory data = _encodeBatch(design, size);
        uint256 calldataGas = _intrinsicCalldataGas(data);

        _warmSharedState();
        uint256 handlerGas = this.measureHandlerLeg(design, size);

        vm.prank(s_swapper);
        uint256 execGas = gasleft();
        (bool ok,) = s_managers[design].call(data);
        execGas -= gasleft();
        assertTrue(ok, "batch reverted");

        string memory row = string.concat(_designName(design), "     ", _pad(rows, 4), _pad(data.length, 8));
        row = string.concat(row, _pad(calldataGas, 10));
        row = string.concat(row, _pad(execGas, 10), _pad(handlerGas, 10), _pad(execGas - handlerGas, 10));
        console.log(string.concat(row, _pad(calldataGas + execGas, 10), _pad((calldataGas + execGas) / rows, 10)));
    }

    /// @dev The stub leg at this length, measured on its own so it can be held out of `manager`.
    ///      Runs in a fresh frame through `this.`: encoding the handler's three memory arrays pays
    ///      memory expansion, which is quadratic and cumulative within a frame, so measuring it inline
    ///      would charge each successive design for the memory the previous ones had already grown.
    function measureHandlerLeg(uint256 design, uint256 size) external returns (uint256 gasUsed) {
        uint256 rows = s_batchSizes[size];
        address[] memory buyers = new address[](rows);
        uint64[] memory scheduleIds = new uint64[](rows);
        uint256[] memory purchaseAmounts = new uint256[](rows);
        for (uint256 i; i < rows; ++i) {
            buyers[i] = s_buyers[i];
            scheduleIds[i] = uint64(i + 1);
            purchaseAmounts[i] = PURCHASE_AMOUNT;
        }
        gasUsed = gasleft();
        s_handlers[design][size].batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, 0);
        gasUsed -= gasleft();
    }

    /**
     * @dev Rootstock's intrinsic calldata cost for the exact bytes a swapper would send: 4 gas per zero
     *      byte and 16 per non-zero, as on Ethereum since EIP-2028, plus 12 gas for every 32-byte word.
     *      That last term is Rootstock's own and is not in any Ethereum schedule, so a figure computed
     *      from Ethereum's rules understates what the swapper pays here.
     *
     *      Measured against Rootstock mainnet rather than assumed, with `eth_estimateGas` on a plain
     *      transfer carrying a payload of `n` zero bytes and then `n` non-zero bytes:
     *
     *          bytes     0    100    200   1000   2000
     *          zeros     0   +448   +884  +4384  +8756
     *          non-zero  0  +1648  +3284 +16384 +32756
     *
     *      over a 21,060 base. Non-zero minus zero is exactly 12 gas per byte at every size, which fixes
     *      the pair at 16/4 rather than the pre-Istanbul 68/4. The remainder over 4 and 16 per byte is
     *      12 x ceil(bytes / 32) at all four sizes: 48, 84, 384, 756.
     */
    function _intrinsicCalldataGas(bytes memory data) private pure returns (uint256 gasCost) {
        for (uint256 i; i < data.length; ++i) {
            gasCost += data[i] == 0 ? 4 : 16;
        }
        gasCost += 12 * ((data.length + 31) / 32);
    }

    function _encodeBatch(uint256 design, uint256 size) private view returns (bytes memory) {
        uint256 rows = s_batchSizes[size];
        uint256 offset = _offsetOf(size);
        address token = s_tokens[design][size];

        uint64[] memory scheduleIds = new uint64[](rows);
        address[] memory buyers = new address[](rows);
        uint256[] memory scheduleIndexes = new uint256[](rows);
        uint256[] memory purchaseAmounts = new uint256[](rows);
        for (uint256 i; i < rows; ++i) {
            buyers[i] = s_buyers[offset + i];
            scheduleIds[i] = uint64(offset + i + 1);
            scheduleIndexes[i] = 0; // one schedule per buyer, which is the common shape
            purchaseAmounts[i] = PURCHASE_AMOUNT;
        }

        if (design == 0) {
            // R66 packed each row as (scheduleId << 96 | expectedPurchaseAmount); every schedule here
            // shares PURCHASE_AMOUNT, so the row matches storage and no benchmark run skips a row.
            bytes32[] memory currentDesignRows = new bytes32[](rows);
            for (uint256 i; i < rows; ++i) {
                currentDesignRows[i] = bytes32((uint256(scheduleIds[i]) << 96) | uint256(uint96(PURCHASE_AMOUNT)));
            }
            return abi.encodeCall(
                IDcaManager.batchBuyRbtc,
                (
                    IDcaManager.Batch({
                        rows: currentDesignRows,
                        token: token,
                        routeIndex: ROUTE_INDEX,
                        minRbtcOutRate: 0
                    })
                )
            );
        }
        if (design == 1) {
            return abi.encodeCall(
                NestedIndexedDcaManager.batchBuyRbtc,
                (
                    NestedIndexedDcaManager.Batch({
                        buyers: buyers,
                        token: token,
                        scheduleIndexes: scheduleIndexes,
                        scheduleIds: scheduleIds,
                        purchaseAmounts: purchaseAmounts,
                        routeIndex: ROUTE_INDEX,
                        minRbtcOut: 0
                    })
                )
            );
        }
        if (design == 2) {
            return abi.encodeCall(
                FlatKeyedDcaManager.batchBuyRbtc,
                (
                    FlatKeyedDcaManager.Batch({
                        scheduleIds: scheduleIds,
                        token: token,
                        routeIndex: ROUTE_INDEX,
                        minRbtcOut: 0
                    })
                )
            );
        }
        if (design == 3) {
            return abi.encodeCall(
                UserKeyedDcaManager.batchBuyRbtc,
                (
                    UserKeyedDcaManager.Batch({
                        scheduleIds: scheduleIds,
                        buyers: buyers,
                        purchaseAmounts: purchaseAmounts,
                        token: token,
                        routeIndex: ROUTE_INDEX,
                        minRbtcOut: 0
                    })
                )
            );
        }
        if (design == 4) {
            return abi.encodeCall(
                TokenKeyedDcaManager.batchBuyRbtc,
                (
                    TokenKeyedDcaManager.Batch({
                        scheduleIds: scheduleIds,
                        token: token,
                        routeIndex: ROUTE_INDEX,
                        minRbtcOut: 0
                    })
                )
            );
        }
        if (design == 5) {
            return abi.encodeCall(
                RouteIdDcaManager.batchBuyRbtc,
                (RouteIdDcaManager.Batch({scheduleIds: scheduleIds, routeId: s_routeIdsF[size], minRbtcOut: 0}))
            );
        }
        if (design == 6) {
            return abi.encodeCall(
                TripleKeyedDcaManager.batchBuyRbtc,
                (
                    TripleKeyedDcaManager.Batch({
                        scheduleIds: scheduleIds,
                        buyers: buyers,
                        token: token,
                        routeIndex: ROUTE_INDEX,
                        minRbtcOut: 0
                    })
                )
            );
        }
        if (design == 7) {
            bytes32[] memory packedRows = new bytes32[](rows);
            for (uint256 i; i < rows; ++i) {
                packedRows[i] = bytes32((uint256(scheduleIds[i]) << 160) | uint256(uint160(buyers[i])));
            }
            return abi.encodeCall(
                PackedRowDcaManager.batchBuyRbtc,
                (
                    PackedRowDcaManager.Batch({
                        rows: packedRows,
                        token: token,
                        routeIndex: ROUTE_INDEX,
                        minRbtcOut: 0
                    })
                )
            );
        }
        return abi.encodeCall(
            UserTokenIdDcaManager.batchBuyRbtc,
            (
                UserTokenIdDcaManager.Batch({
                    scheduleIds: scheduleIds,
                    buyers: buyers,
                    token: token,
                    routeIndex: ROUTE_INDEX,
                    minRbtcOut: 0
                })
            )
        );
    }

    function _buy(uint256 design, uint256 size) private {
        bytes memory data = _encodeBatch(design, size);
        vm.prank(s_swapper);
        (bool ok,) = s_managers[design].call(data);
        assertTrue(ok, "warm-up batch reverted");
    }

    /**
     * @dev Touch what every design pays for identically, and nothing else. The swapper allowlist and the
     *      handler accounts qualify: the same one lookup and the same one external account, whatever the
     *      key looks like. The route records deliberately do not — the designs read a different number
     *      of slots there, which is part of what is being measured. Idempotent, and always called
     *      outside a measurement window.
     */
    function _warmSharedState() private view {
        s_operationsAdmin.isSwapper(s_swapper);
        s_routeIdRegistry.isSwapper(s_swapper);
        for (uint256 d; d < DESIGNS; ++d) {
            for (uint256 s; s < SIZES; ++s) {
                s_handlers[d][s].rowsBought();
                s_handlers[d][s].deposits();
            }
        }
    }

    /// @dev Where each size group starts in `s_buyers`; group `s` owns `s_batchSizes[s]` consecutive ids.
    function _offsetOf(uint256 size) private view returns (uint256 offset) {
        offset = FIRST_SCHEDULE;
        for (uint256 s; s < size; ++s) {
            offset += s_batchSizes[s];
        }
    }

    /// @dev Which size group buyer `i` belongs to. Buyer 0 rides with the first group; its schedule is
    ///      never batched, and exists only so ids start above zero.
    function _groupOf(uint256 index) private view returns (uint256) {
        uint256 offset = FIRST_SCHEDULE;
        for (uint256 s; s < SIZES; ++s) {
            offset += s_batchSizes[s];
            if (index < offset) return s;
        }
        return SIZES - 1;
    }

    function _designName(uint256 design) private pure returns (string memory) {
        if (design == 0) return "A";
        if (design == 1) return "B";
        if (design == 2) return "C";
        if (design == 3) return "D";
        if (design == 4) return "E";
        if (design == 5) return "F";
        if (design == 6) return "G";
        if (design == 7) return "H";
        return "I";
    }

    function _pad(uint256 value, uint256 width) private pure returns (string memory padded) {
        padded = vm.toString(value);
        while (bytes(padded).length < width) {
            padded = string.concat(" ", padded);
        }
    }
}
