// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {StubPurchaseHandler} from "./StubPurchaseHandler.sol";
import {NestedIndexedDcaManager} from "./prototype/NestedIndexedDcaManager.sol";
import {FlatKeyedDcaManager} from "./prototype/FlatKeyedDcaManager.sol";
import {UserKeyedDcaManager} from "./prototype/UserKeyedDcaManager.sol";
import {TokenKeyedDcaManager} from "./prototype/TokenKeyedDcaManager.sol";

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

    uint256 private constant DESIGNS = 5;

    address private constant TOKEN_A = address(uint160(uint256(keccak256("R64.token.A"))));
    address private constant TOKEN_B = address(uint160(uint256(keccak256("R64.token.B"))));
    address private constant TOKEN_C = address(uint160(uint256(keccak256("R64.token.C"))));
    address private constant TOKEN_D = address(uint160(uint256(keccak256("R64.token.D"))));
    address private constant TOKEN_E = address(uint160(uint256(keccak256("R64.token.E"))));

    address private s_swapper;

    OperationsAdmin private s_operationsAdmin;
    DcaManager private s_designA;
    NestedIndexedDcaManager private s_designB;
    FlatKeyedDcaManager private s_designC;
    UserKeyedDcaManager private s_designD;
    TokenKeyedDcaManager private s_designE;

    /// @dev One per design, indexed by design number, so the loops do not branch on it.
    address[DESIGNS] private s_managers;
    address[DESIGNS] private s_tokens;
    StubPurchaseHandler[DESIGNS] private s_handlers;

    /// @dev Buyer `i` owns schedule `i` on every design; ids run 1..261 in the same order on all five.
    address[] private s_buyers;

    function setUp() public {
        vm.warp(START_TIMESTAMP);
        s_swapper = makeAddr("swapper");

        s_operationsAdmin = new OperationsAdmin(address(this));
        s_operationsAdmin.addSwapper(s_swapper);

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
        s_managers = [address(s_designA), address(s_designB), address(s_designC), address(s_designD), address(s_designE)];
        s_tokens = [TOKEN_A, TOKEN_B, TOKEN_C, TOKEN_D, TOKEN_E];

        for (uint256 d; d < DESIGNS; ++d) {
            s_handlers[d] = new StubPurchaseHandler();
            s_operationsAdmin.assignTokenHandler(s_tokens[d], ROUTE_INDEX, address(s_handlers[d]));
        }

        for (uint256 i; i < TOTAL_SCHEDULES + FIRST_SCHEDULE; ++i) {
            address buyer = address(uint160(uint256(keccak256(abi.encode("R64.buyer", i)))));
            s_buyers.push(buyer);
            vm.startPrank(buyer);
            s_designA.createDcaSchedule(TOKEN_A, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designB.createDcaSchedule(TOKEN_B, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designC.createDcaSchedule(TOKEN_C, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designD.createDcaSchedule(TOKEN_D, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
            s_designE.createDcaSchedule(TOKEN_E, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
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

        for (uint256 d; d < DESIGNS; ++d) {
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

        // Design B is the keying `DcaManager` had before R64, and its cold paths are the ones that were
        // measured on the real contract then: 91,622 to create and 11,122 to delete, under
        // [profile.default]. Holding the prototype to those figures is what keeps it a baseline rather
        // than a sketch — if it drifts from the design it claims to reproduce, the run fails instead of
        // quietly flattering the change. The band is 10% because this assertion has to hold under both
        // profiles and via-IR takes about 6% off a cold path; a keying change moves these by ~50%, which
        // is the drift it exists to catch.
        assertApproxEqRel(createGas[1], 91_622, 0.10e18, "prototype B no longer reproduces the pre-R64 create");
        assertApproxEqRel(deleteGas[1], 11_122, 0.10e18, "prototype B no longer reproduces the pre-R64 delete");
    }

    /// @dev One create and one delete on `design`, as the same fresh user, measured separately.
    function _coldPathGas(uint256 design, address user) private returns (uint256 createGas, uint256 deleteGas) {
        address token = s_tokens[design];

        createGas = gasleft();
        if (design == 0) s_designA.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 1) s_designB.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 2) s_designC.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else if (design == 3) s_designD.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        else s_designE.createDcaSchedule(token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        createGas -= gasleft();

        uint64 scheduleId = _lastCreatedId(design, user, token);

        deleteGas = gasleft();
        if (design == 0) s_designA.deleteDcaSchedule(scheduleId);
        else if (design == 1) s_designB.deleteDcaSchedule(token, 0, scheduleId);
        else if (design == 2) s_designC.deleteDcaSchedule(scheduleId);
        else if (design == 3) s_designD.deleteDcaSchedule(scheduleId);
        else s_designE.deleteDcaSchedule(token, scheduleId);
        deleteGas -= gasleft();
    }

    function _lastCreatedId(uint256 design, address user, address token) private view returns (uint64) {
        if (design == 0) return s_designA.getDcaSchedules(user, token)[0].scheduleId;
        if (design == 1) return s_designB.getDcaSchedules(user, token)[0].scheduleId;
        if (design == 2) return uint64(s_designC.getSchedulesCreatedCount());
        if (design == 3) return uint64(s_designD.getSchedulesCreatedCount());
        return uint64(s_designE.getSchedulesCreatedCount());
    }

    /*//////////////////////////////////////////////////////////////
                             SANITY CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev The three designs must debit the same schedules by the same amount, or the gas table is
    ///      comparing different work. Asserted rather than assumed.
    function test_r64_designsAgreeOnEffects() public {
        uint256 rows = 10;
        uint256 offset = FIRST_SCHEDULE;
        uint64 scheduleId = uint64(offset + 1);
        address buyer = s_buyers[offset];

        uint256 balanceBefore = s_designA.getDcaSchedules(buyer, TOKEN_A)[0].tokenBalance;
        assertEq(s_designE.getSchedule(scheduleId, TOKEN_E).tokenBalance, balanceBefore, "designs disagree before");

        for (uint256 d; d < DESIGNS; ++d) {
            _buy(d, rows, offset);
        }

        uint256 expected = balanceBefore - PURCHASE_AMOUNT;
        assertEq(s_designA.getDcaSchedules(buyer, TOKEN_A)[0].tokenBalance, expected, "A debited wrongly");
        assertEq(s_designB.getDcaSchedules(buyer, TOKEN_B)[0].tokenBalance, expected, "B debited wrongly");
        assertEq(s_designC.getSchedule(scheduleId).tokenBalance, expected, "C debited wrongly");
        assertEq(s_designD.getSchedule(scheduleId, buyer).tokenBalance, expected, "D debited wrongly");
        assertEq(s_designE.getSchedule(scheduleId, TOKEN_E).tokenBalance, expected, "E debited wrongly");

        for (uint256 d = 1; d < DESIGNS; ++d) {
            assertEq(s_handlers[d].rowsBought(), s_handlers[0].rowsBought(), "designs bought a different row count");
        }
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
        gasUsed = gasleft();
        s_handlers[design].batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, 0);
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
                scheduleIds: scheduleIds,
                buyers: buyers,
                token: TOKEN_A,
                routeIndex: ROUTE_INDEX,
                minRbtcOut: 0
            });
            return abi.encodeCall(IDcaManager.batchBuyRbtc, (batch));
        }
        if (design == 1) {
            NestedIndexedDcaManager.Batch memory batch = NestedIndexedDcaManager.Batch({
                buyers: buyers,
                token: TOKEN_B,
                scheduleIndexes: scheduleIndexes,
                scheduleIds: scheduleIds,
                purchaseAmounts: purchaseAmounts,
                routeIndex: ROUTE_INDEX,
                minRbtcOut: 0
            });
            return abi.encodeCall(NestedIndexedDcaManager.batchBuyRbtc, (batch));
        }
        if (design == 2) {
            FlatKeyedDcaManager.Batch memory flatBatch = FlatKeyedDcaManager.Batch({
                scheduleIds: scheduleIds,
                token: TOKEN_C,
                routeIndex: ROUTE_INDEX,
                minRbtcOut: 0
            });
            return abi.encodeCall(FlatKeyedDcaManager.batchBuyRbtc, (flatBatch));
        }
        if (design == 3) {
            UserKeyedDcaManager.Batch memory userBatch = UserKeyedDcaManager.Batch({
                scheduleIds: scheduleIds,
                buyers: buyers,
                purchaseAmounts: purchaseAmounts,
                token: TOKEN_D,
                routeIndex: ROUTE_INDEX,
                minRbtcOut: 0
            });
            return abi.encodeCall(UserKeyedDcaManager.batchBuyRbtc, (userBatch));
        }
        TokenKeyedDcaManager.Batch memory tokenBatch = TokenKeyedDcaManager.Batch({
            scheduleIds: scheduleIds,
            purchaseAmounts: purchaseAmounts,
            token: TOKEN_E,
            routeIndex: ROUTE_INDEX,
            minRbtcOut: 0
        });
        return abi.encodeCall(TokenKeyedDcaManager.batchBuyRbtc, (tokenBatch));
    }

    function _buy(uint256 design, uint256 rows, uint256 offset) private {
        bytes memory data = _encodeBatch(design, rows, offset);
        vm.prank(s_swapper);
        (bool ok,) = _manager(design).call(data);
        assertTrue(ok, "warm-up batch reverted");
    }

    function _buyAll(uint256 offset, uint256 rows) private {
        for (uint256 d; d < DESIGNS; ++d) {
            _buy(d, rows, offset);
        }
    }

    /// @dev Touch every account and registry slot the three designs share, so the first design measured
    ///      does not pay cold-access costs the other two then find warm. Idempotent, and always called
    ///      outside a measurement window.
    function _warmSharedState() private view {
        for (uint256 d; d < DESIGNS; ++d) {
            s_operationsAdmin.getTokenHandler(s_tokens[d], ROUTE_INDEX);
            s_handlers[d].rowsBought();
            s_handlers[d].deposits();
        }
        s_designA.getSchedulesCreatedCount();
        s_designB.getSchedulesCreatedCount();
        s_designC.getSchedulesCreatedCount();
        s_designD.getSchedulesCreatedCount();
        s_designE.getSchedulesCreatedCount();
    }

    function _manager(uint256 design) private view returns (address) {
        return s_managers[design];
    }

    function _designName(uint256 design) private pure returns (string memory) {
        if (design == 0) return "A";
        if (design == 1) return "B";
        if (design == 2) return "C";
        if (design == 3) return "D";
        return "E";
    }

    function _pad(uint256 value, uint256 width) private pure returns (string memory padded) {
        padded = vm.toString(value);
        while (bytes(padded).length < width) {
            padded = string.concat(" ", padded);
        }
    }
}
