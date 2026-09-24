// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {
    R79Slots,
    R79SovrynHandler,
    R79IdleHandler
} from "test/unit/R79CoalescedWritesDifferential.t.sol";

/**
 * @title R79RepeatedBuyerWritesGas
 * @notice Counts the writes and reads a handler batch makes to each buyer's balance slots, and logs
 *         Foundry gas for a five-row batch with one buyer and with five.
 * @dev Reproduce with:
 *
 *          forge test --match-path test/gas/R79RepeatedBuyerWritesGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R79RepeatedBuyerWritesGas.t.sol -vv
 *
 *      The write count is what Rootstock prices: every write to a nonzero slot is a 5,000 `RESET` there,
 *      even when the transaction wrote that slot a moment earlier, and every read is a flat 200. Foundry
 *      charges a warm rewrite about 100, so its gas is logged only as a same-build regression figure.
 *
 *      Pinned: one write per contiguous run on each buyer slot (accumulated rBTC, plus lending shares or
 *      idle balance), on both profiles, whatever the order of the batch.
 */
contract R79RepeatedBuyerWritesGasTest is Test {
    uint256 internal constant ROWS = 5;
    uint256 internal constant DEPOSIT = 300 ether;
    uint256 internal constant AMOUNT = 20 ether;

    MockStablecoin internal stablecoin;
    MockIsusdToken internal iSusd;
    R79SovrynHandler internal lending;
    R79IdleHandler internal idle;
    address[ROWS] internal pool = [address(0xA11CE), address(0xB0B), address(0xCA7), address(0xD06), address(0xE7E)];

    function setUp() public {
        stablecoin = new MockStablecoin(address(this));
        iSusd = new MockIsusdToken(address(stablecoin));
        stablecoin.mint(address(iSusd), 1_000_000 ether);
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: 100, maxFeeRate: 100, feePurchaseLowerBound: 1000 ether, feePurchaseUpperBound: 100_000 ether
        });
        lending = new R79SovrynHandler(address(this), address(stablecoin), address(iSusd), feeSettings);
        idle = new R79IdleHandler(address(this), address(stablecoin), feeSettings);
        lending.setRbtcOut(1 ether);
        idle.setRbtcOut(1 ether);

        for (uint256 i; i < ROWS; ++i) {
            stablecoin.mint(pool[i], 2 * DEPOSIT);
            vm.startPrank(pool[i]);
            stablecoin.approve(address(lending), type(uint256).max);
            stablecoin.approve(address(idle), type(uint256).max);
            vm.stopPrank();
            lending.depositToken(pool[i], DEPOSIT);
            idle.depositToken(pool[i], DEPOSIT);
            // Every buyer already holds live rBTC, so each credit is a nonzero-to-nonzero write as in steady state.
            vm.store(address(lending), R79Slots.key(pool[i], R79Slots.ACCUMULATED_RBTC), bytes32(uint256(2)));
            vm.store(address(idle), R79Slots.key(pool[i], R79Slots.ACCUMULATED_RBTC), bytes32(uint256(2)));
        }
    }

    /*//////////////////////////////////////////////////////////////
                              WRITE COUNTS
    //////////////////////////////////////////////////////////////*/

    function test_writes_sameBuyer() public {
        _assertRuns("same buyer", _order([uint256(0), 0, 0, 0, 0]), [uint256(1), 0, 0, 0, 0]);
    }

    function test_writes_clustered() public {
        _assertRuns("clustered", _order([uint256(0), 0, 1, 1, 1]), [uint256(1), 1, 0, 0, 0]);
    }

    function test_writes_uniqueBuyers() public {
        _assertRuns("unique", _order([uint256(0), 1, 2, 3, 4]), [uint256(1), 1, 1, 1, 1]);
    }

    function test_writes_unsortedDuplicates() public {
        _assertRuns("unsorted", _order([uint256(0), 1, 0, 1, 0]), [uint256(3), 2, 0, 0, 0]);
    }

    /*//////////////////////////////////////////////////////////////
                              FOUNDRY GAS
    //////////////////////////////////////////////////////////////*/

    function test_gas_fiveRows() public {
        address[] memory same = _order([uint256(0), 0, 0, 0, 0]);
        address[] memory unique = _order([uint256(0), 1, 2, 3, 4]);
        console2.log("lending same buyer   ", _gas(address(lending), same));
        console2.log("lending unique buyers", _gas(address(lending), unique));
        console2.log("idle same buyer      ", _gas(address(idle), same));
        console2.log("idle unique buyers   ", _gas(address(idle), unique));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev For each handler, count accesses to each pool buyer's balance slots and pin writes to `runs`.
    function _assertRuns(string memory label, address[] memory buyers, uint256[ROWS] memory runs) private {
        _assertRunsOn(label, address(lending), R79Slots.SHARES, buyers, runs);
        _assertRunsOn(label, address(idle), R79Slots.IDLE_BALANCES, buyers, runs);
    }

    function _assertRunsOn(
        string memory label,
        address handler,
        uint256 balanceBase,
        address[] memory buyers,
        uint256[ROWS] memory runs
    ) private {
        uint256 snap = vm.snapshot();
        vm.startStateDiffRecording();
        _buy(handler, buyers);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.revertTo(snap);

        console2.log(label, handler == address(lending) ? "lending" : "idle");
        uint256[ROWS] memory balanceWrites;
        uint256[ROWS] memory rbtcWrites;
        for (uint256 i; i < ROWS; ++i) {
            bytes32 balanceSlot = R79Slots.key(pool[i], balanceBase);
            bytes32 rbtcSlot = R79Slots.key(pool[i], R79Slots.ACCUMULATED_RBTC);
            balanceWrites[i] = _count(accesses, handler, balanceSlot, true);
            rbtcWrites[i] = _count(accesses, handler, rbtcSlot, true);
            if (balanceWrites[i] + rbtcWrites[i] == 0) continue;
            console2.log("  buyer", i);
            console2.log("    balance writes / reads", balanceWrites[i], _count(accesses, handler, balanceSlot, false));
            console2.log("    rBTC    writes / reads", rbtcWrites[i], _count(accesses, handler, rbtcSlot, false));
        }
        for (uint256 i; i < ROWS; ++i) {
            assertEq(balanceWrites[i], runs[i], "balance slot not written once per run");
            assertEq(rbtcWrites[i], runs[i], "rBTC slot not written once per run");
        }
    }

    function _gas(address handler, address[] memory buyers) private returns (uint256 used) {
        uint256 snap = vm.snapshot();
        _cool(handler);
        _cool(address(stablecoin));
        _cool(address(iSusd));
        uint256 before = gasleft();
        _buy(handler, buyers);
        used = before - gasleft();
        vm.revertTo(snap);
    }

    function _buy(address handler, address[] memory buyers) private {
        uint64[] memory ids = new uint64[](buyers.length);
        uint256[] memory amounts = new uint256[](buyers.length);
        for (uint256 i; i < buyers.length; ++i) {
            ids[i] = uint64(i + 1);
            amounts[i] = AMOUNT;
        }
        R79IdleHandler(payable(handler)).batchBuyRbtc(buyers, ids, amounts, 0);
    }

    function _order(uint256[ROWS] memory indexes) private view returns (address[] memory buyers) {
        buyers = new address[](ROWS);
        for (uint256 i; i < ROWS; ++i) {
            buyers[i] = pool[indexes[i]];
        }
    }

    function _count(Vm.AccountAccess[] memory accesses, address account, bytes32 slot, bool writes)
        private
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                if (
                    storageAccesses[j].account == account && storageAccesses[j].slot == slot
                        && storageAccesses[j].isWrite == writes
                ) ++count;
            }
        }
    }

    /// @dev forge-std's `Vm` interface on this pin omits `cool`; the cheatcode exists on the binary.
    function _cool(address target) private {
        (bool ok,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("cool(address)", target));
        require(ok, "vm.cool unavailable");
    }
}
