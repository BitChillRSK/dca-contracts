// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {StubPurchaseHandler} from "./StubPurchaseHandler.sol";
import {NestedNoGuardDcaManager} from "./prototype/NestedNoGuardDcaManager.sol";
import {FlatKeyedDcaManager} from "./prototype/FlatKeyedDcaManager.sol";

/**
 * @title R64BatchGasBenchmark
 * @notice Prices the two coupled choices R64 exists to decide: whether the `Batch` staleness guard
 *         earns its calldata, and whether a flat `mapping(uint64 => DcaSchedule)` beats today's
 *         nested one on the path the swapper pays every day.
 * @dev Reproduce the table with:
 *
 *          forge test --match-path 'test/gas/*' -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path 'test/gas/*' -vv
 *
 *      Three designs, one stub handler, identical schedules:
 *        A — `src/DcaManager` as it stands: nested storage, four parallel arrays per batch.
 *        B — nested storage, no `purchaseAmounts` array. The A→B delta is the guard's price.
 *        C — flat `mapping(uint64 => …)`, one `uint64` per row. The A→C delta is the keying's price.
 *
 *      What each column means:
 *        `calldata`  Intrinsic transaction cost of the encoded call, 4 gas per zero byte and 16 per
 *                    non-zero (EIP-2028). Computed from the bytes actually sent, not estimated. A test
 *                    calling a contract never pays this — a swapper sending a transaction always does,
 *                    so it has to be added back by hand or the whole comparison misses the point.
 *        `exec`      Gas the call itself burned, measured around a raw `call` with those same bytes.
 *        `handler`   The stub handler leg inside `exec`, measured separately at the same length. It is
 *                    identical across designs by construction; a real venue's cost is far larger and
 *                    equally identical, which is exactly why it is held out of the comparison.
 *        `manager`   `exec - handler`: the schedule bookkeeping, which is what the design changes.
 *        `total`     `calldata + exec`, the operator's bill for the batch.
 *
 *      Every measurement runs after a warm-up batch, so the `OperationsAdmin` lookup and the handler
 *      account are warm in all three designs and the sizes stay comparable to each other. A real tick's
 *      first row additionally pays those cold accesses once (~4.7k), which no design avoids. Each size
 *      uses its own schedules, created in `setUp` and purchased once there, so the measured tick is a
 *      steady-state one reading cold schedule slots — what the swapper actually meets.
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

    /// @dev Batch sizes the spec asks for.
    uint256[4] private s_batchSizes = [uint256(1), 10, 50, 200];
    uint256 private constant TOTAL_SCHEDULES = 261; // 1 + 10 + 50 + 200
    /// @dev Schedule 0 is never batched; it exists so the size groups start at a non-zero offset.
    uint256 private constant FIRST_SCHEDULE = 1;

    address private constant TOKEN_A = address(uint160(uint256(keccak256("R64.token.A"))));
    address private constant TOKEN_B = address(uint160(uint256(keccak256("R64.token.B"))));
    address private constant TOKEN_C = address(uint160(uint256(keccak256("R64.token.C"))));

    address private s_swapper;

    OperationsAdmin private s_operationsAdmin;
    DcaManager private s_designA;
    NestedNoGuardDcaManager private s_designB;
    FlatKeyedDcaManager private s_designC;
    StubPurchaseHandler private s_handlerA;
    StubPurchaseHandler private s_handlerB;
    StubPurchaseHandler private s_handlerC;

    /// @dev Buyer `i` owns schedule `i` on every design; ids run 1..261 in the same order on all three.
    address[] private s_buyers;

    function setUp() public {
        vm.warp(START_TIMESTAMP);
        s_swapper = makeAddr("swapper");

        s_operationsAdmin = new OperationsAdmin(address(this));
        s_operationsAdmin.addSwapper(s_swapper);

        s_handlerA = new StubPurchaseHandler();
        s_handlerB = new StubPurchaseHandler();
        s_handlerC = new StubPurchaseHandler();
        s_operationsAdmin.assignTokenHandler(TOKEN_A, ROUTE_INDEX, address(s_handlerA));
        s_operationsAdmin.assignTokenHandler(TOKEN_B, ROUTE_INDEX, address(s_handlerB));
        s_operationsAdmin.assignTokenHandler(TOKEN_C, ROUTE_INDEX, address(s_handlerC));

        s_designA = new DcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, address(this)
        );
        s_designB = new NestedNoGuardDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );
        s_designC = new FlatKeyedDcaManager(
            address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );

        for (uint256 i; i < TOTAL_SCHEDULES + FIRST_SCHEDULE; ++i) {
            address buyer = address(uint160(uint256(keccak256(abi.encode("R64.buyer", i)))));
            s_buyers.push(buyer);
            vm.startPrank(buyer);
            s_designA.createDcaSchedule(TOKEN_A, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designB.createDcaSchedule(TOKEN_B, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designC.createDcaSchedule(TOKEN_C, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            vm.stopPrank();
        }

        // One purchase over every schedule, so the measured tick is a steady-state one rather than a
        // first purchase, which takes a different branch and writes a zero timestamp.
        _buyAll(0, TOTAL_SCHEDULES + FIRST_SCHEDULE);
        vm.warp(START_TIMESTAMP + 2 days);
    }

    /*//////////////////////////////////////////////////////////////
                              BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function test_r64_batchGasByDesign() public {
        console.log("");
        console.log("R64 batchBuyRbtc, steady-state tick, gas");
        console.log("design  rows   bytes  calldata      exec   handler   manager     total   per-row");

        for (uint256 d; d < 3; ++d) {
            uint256 offset = FIRST_SCHEDULE;
            for (uint256 s; s < s_batchSizes.length; ++s) {
                uint256 rows = s_batchSizes[s];
                _report(d, rows, offset);
                offset += rows;
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
        vm.startPrank(user);

        uint256 createA = gasleft();
        s_designA.createDcaSchedule(TOKEN_A, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        createA -= gasleft();
        uint256 createB = gasleft();
        s_designB.createDcaSchedule(TOKEN_B, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        createB -= gasleft();
        uint256 createC = gasleft();
        s_designC.createDcaSchedule(TOKEN_C, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        createC -= gasleft();

        uint64 idA = s_designA.getDcaSchedules(user, TOKEN_A)[0].scheduleId;
        uint64 idB = s_designB.getDcaSchedules(user, TOKEN_B)[0].scheduleId;
        uint64 idC = uint64(s_designC.getSchedulesCreatedCount());

        uint256 deleteA = gasleft();
        s_designA.deleteDcaSchedule(TOKEN_A, 0, idA);
        deleteA -= gasleft();
        uint256 deleteB = gasleft();
        s_designB.deleteDcaSchedule(TOKEN_B, 0, idB);
        deleteB -= gasleft();
        uint256 deleteC = gasleft();
        s_designC.deleteDcaSchedule(idC);
        deleteC -= gasleft();

        vm.stopPrank();

        console.log(string.concat("A      ", _pad(createA, 9), _pad(deleteA, 10)));
        console.log(string.concat("B      ", _pad(createB, 9), _pad(deleteB, 10)));
        console.log(string.concat("C      ", _pad(createC, 9), _pad(deleteC, 10)));
        console.log("");

        // Design B keeps A's storage and cold paths exactly; only the batch differs. If its create or
        // delete drifts from A's, the prototype has stopped reproducing the contract and every number
        // above it is measuring the wrong thing.
        assertApproxEqRel(createB, createA, 0.02e18, "prototype B no longer reproduces DcaManager's create");
        assertApproxEqRel(deleteB, deleteA, 0.05e18, "prototype B no longer reproduces DcaManager's delete");
    }

    /*//////////////////////////////////////////////////////////////
                             SANITY CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev The three designs must debit the same schedules by the same amount, or the gas table is
    ///      comparing different work. Asserted rather than assumed.
    function test_r64_designsAgreeOnEffects() public {
        uint256 rows = 10;
        uint256 offset = FIRST_SCHEDULE;

        uint256 balanceBeforeA = s_designA.getDcaSchedules(s_buyers[offset], TOKEN_A)[0].tokenBalance;
        uint256 balanceBeforeC = s_designC.getSchedule(uint64(offset + 1)).tokenBalance;
        assertEq(balanceBeforeA, balanceBeforeC, "designs disagree before the tick");

        _buy(0, rows, offset);
        _buy(1, rows, offset);
        _buy(2, rows, offset);

        assertEq(
            s_designA.getDcaSchedules(s_buyers[offset], TOKEN_A)[0].tokenBalance,
            balanceBeforeA - PURCHASE_AMOUNT,
            "design A debited the wrong amount"
        );
        assertEq(
            s_designB.getDcaSchedules(s_buyers[offset], TOKEN_B)[0].tokenBalance,
            balanceBeforeA - PURCHASE_AMOUNT,
            "design B debited the wrong amount"
        );
        assertEq(
            s_designC.getSchedule(uint64(offset + 1)).tokenBalance,
            balanceBeforeA - PURCHASE_AMOUNT,
            "design C debited the wrong amount"
        );
        assertEq(s_handlerA.rowsBought(), s_handlerC.rowsBought(), "designs bought a different number of rows");
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _report(uint256 design, uint256 rows, uint256 offset) private {
        bytes memory data = _encodeBatch(design, rows, offset);
        uint256 calldataGas = _intrinsicCalldataGas(data);

        _warmSharedState();
        uint256 handlerGas = this.measureHandlerLeg(design, rows);

        vm.prank(s_swapper);
        uint256 execGas = gasleft();
        (bool ok,) = _manager(design).call(data);
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
    function measureHandlerLeg(uint256 design, uint256 rows) external returns (uint256 gasUsed) {
        address[] memory buyers = new address[](rows);
        uint64[] memory scheduleIds = new uint64[](rows);
        uint256[] memory purchaseAmounts = new uint256[](rows);
        for (uint256 i; i < rows; ++i) {
            buyers[i] = s_buyers[i];
            scheduleIds[i] = uint64(i + 1);
            purchaseAmounts[i] = PURCHASE_AMOUNT;
        }
        StubPurchaseHandler handler = design == 0 ? s_handlerA : design == 1 ? s_handlerB : s_handlerC;
        gasUsed = gasleft();
        handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, 0);
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

    function _encodeBatch(uint256 design, uint256 rows, uint256 offset) private view returns (bytes memory) {
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
            IDcaManager.Batch memory batch = IDcaManager.Batch({
                buyers: buyers,
                token: TOKEN_A,
                scheduleIndexes: scheduleIndexes,
                scheduleIds: scheduleIds,
                purchaseAmounts: purchaseAmounts,
                routeIndex: ROUTE_INDEX,
                minRbtcOut: 0
            });
            return abi.encodeCall(IDcaManager.batchBuyRbtc, (batch));
        }
        if (design == 1) {
            NestedNoGuardDcaManager.Batch memory batch = NestedNoGuardDcaManager.Batch({
                buyers: buyers,
                token: TOKEN_B,
                scheduleIndexes: scheduleIndexes,
                scheduleIds: scheduleIds,
                routeIndex: ROUTE_INDEX,
                minRbtcOut: 0
            });
            return abi.encodeCall(NestedNoGuardDcaManager.batchBuyRbtc, (batch));
        }
        FlatKeyedDcaManager.Batch memory flatBatch = FlatKeyedDcaManager.Batch({
            scheduleIds: scheduleIds,
            token: TOKEN_C,
            routeIndex: ROUTE_INDEX,
            minRbtcOut: 0
        });
        return abi.encodeCall(FlatKeyedDcaManager.batchBuyRbtc, (flatBatch));
    }

    function _buy(uint256 design, uint256 rows, uint256 offset) private {
        bytes memory data = _encodeBatch(design, rows, offset);
        vm.prank(s_swapper);
        (bool ok,) = _manager(design).call(data);
        assertTrue(ok, "warm-up batch reverted");
    }

    function _buyAll(uint256 offset, uint256 rows) private {
        for (uint256 d; d < 3; ++d) {
            _buy(d, rows, offset);
        }
    }

    /// @dev Touch every account and registry slot the three designs share, so the first design measured
    ///      does not pay cold-access costs the other two then find warm. Idempotent, and always called
    ///      outside a measurement window.
    function _warmSharedState() private view {
        s_operationsAdmin.getTokenHandler(TOKEN_A, ROUTE_INDEX);
        s_operationsAdmin.getTokenHandler(TOKEN_B, ROUTE_INDEX);
        s_operationsAdmin.getTokenHandler(TOKEN_C, ROUTE_INDEX);
        s_handlerA.rowsBought();
        s_handlerB.rowsBought();
        s_handlerC.rowsBought();
        s_handlerA.deposits();
        s_handlerB.deposits();
        s_handlerC.deposits();
        s_designA.getSchedulesCreatedCount();
        s_designB.getSchedulesCreatedCount();
        s_designC.getSchedulesCreatedCount();
    }

    function _manager(uint256 design) private view returns (address) {
        return design == 0 ? address(s_designA) : design == 1 ? address(s_designB) : address(s_designC);
    }

    function _designName(uint256 design) private pure returns (string memory) {
        return design == 0 ? "A" : design == 1 ? "B" : "C";
    }

    function _pad(uint256 value, uint256 width) private pure returns (string memory padded) {
        padded = vm.toString(value);
        while (bytes(padded).length < width) {
            padded = string.concat(" ", padded);
        }
    }
}
