// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IdleErc20Handler} from "src/idle/IdleErc20Handler.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import "test/Constants.sol";

/**
 * @title R87IdleLedgerRemovalGas
 * @notice Old-vs-new idle `_batchRetrieveStablecoin`: baseline keeps the pre-removal per-user ledger;
 *         current is production (sum only). Also asserts the new path writes no mapping slots.
 * @dev Reproduce:
 *
 *          forge test --match-path test/gas/R87IdleLedgerRemovalGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R87IdleLedgerRemovalGas.t.sol -vv
 *
 *      Per-row Rootstock conversion of the removed work: one SLOAD (200) + one RESET (5_000) =
 *      5_200, counted from the baseline's mapping writes (not from the Foundry gas delta). A 10-row
 *      batch therefore saves 52_000 Rootstock gas on the ledger alone. Foundry prints a smaller
 *      Cancun figure because the deposit in `setUp` leaves the slots warm.
 */
contract R87IdleLedgerRemovalGasTest is Test {
    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant ROWS = 10;
    /// @dev Rootstock: 10 × (SLOAD 200 + RESET 5_000).
    uint256 internal constant ROOTSTOCK_LEDGER_SAVING_10_ROWS = 10 * (200 + 5_000);

    address internal constant DCA = address(0xDCA);
    MockStablecoin internal token;
    IdleGasHarness internal current;
    IdleLedgerBaselineHarness internal baseline;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
        current = new IdleGasHarness(DCA, address(token), address(0xFEE), feeSettings, address(this));
        baseline = new IdleLedgerBaselineHarness(DCA, address(token), address(0xFEE), feeSettings, address(this));
    }

    function test_gas_idleDepositWithdrawHaveNoPerUserLedgerWrites() public {
        address user = address(0xA11CE);
        token.mint(user, DEPOSIT * 2);
        vm.prank(user);
        token.approve(address(current), type(uint256).max);

        vm.startStateDiffRecording();
        vm.prank(DCA);
        current.depositToken(user, DEPOSIT);
        Vm.AccountAccess[] memory depositAccesses = vm.stopAndReturnStateDiff();
        assertEq(_mappingValueWrites(depositAccesses, address(current)), 0, "deposit wrote a mapping slot");

        vm.startStateDiffRecording();
        vm.prank(DCA);
        current.withdrawToken(user, DEPOSIT / 2);
        Vm.AccountAccess[] memory withdrawAccesses = vm.stopAndReturnStateDiff();
        assertEq(_mappingValueWrites(withdrawAccesses, address(current)), 0, "withdraw wrote a mapping slot");
    }

    function test_gas_idleBatchFundingOldVersusNew() public {
        address[] memory users = new address[](ROWS);
        uint256[] memory amounts = new uint256[](ROWS);
        for (uint256 i; i < ROWS; ++i) {
            users[i] = address(uint160(0x1000 + i));
            amounts[i] = DEPOSIT / 2;
            token.mint(users[i], DEPOSIT * 2);
            vm.prank(users[i]);
            token.approve(address(current), type(uint256).max);
            vm.prank(users[i]);
            token.approve(address(baseline), type(uint256).max);
            vm.prank(DCA);
            current.depositToken(users[i], DEPOSIT);
            vm.prank(DCA);
            baseline.depositToken(users[i], DEPOSIT);
        }

        // Deposits leave ledger slots dirty in this tx. Foundry then prices the baseline debit as a
        // warm RESET (~100) rather than a cold one; Rootstock still charges 5_000 per nonzero write.
        // Convert with the access count below, not the Foundry gas delta.
        uint256 snap = vm.snapshot();

        vm.startStateDiffRecording();
        uint256 gasCurrentBefore = gasleft();
        uint256 totalCurrent = current.exposedBatchRetrieve(users, amounts);
        uint256 gasCurrent = gasCurrentBefore - gasleft();
        Vm.AccountAccess[] memory currentAccesses = vm.stopAndReturnStateDiff();

        vm.revertTo(snap);

        vm.startStateDiffRecording();
        uint256 gasBaselineBefore = gasleft();
        uint256 totalBaseline = baseline.exposedBatchRetrieve(users, amounts);
        uint256 gasBaseline = gasBaselineBefore - gasleft();
        Vm.AccountAccess[] memory baselineAccesses = vm.stopAndReturnStateDiff();

        assertEq(totalCurrent, totalBaseline);
        assertEq(totalCurrent, (DEPOSIT / 2) * ROWS);
        assertEq(_mappingValueWrites(currentAccesses, address(current)), 0, "new path wrote a mapping slot");
        uint256 baselineMapWrites = _mappingValueWrites(baselineAccesses, address(baseline));
        assertEq(baselineMapWrites, ROWS, "baseline should write one ledger slot per row");
        assertGt(gasBaseline, gasCurrent, "ledger baseline should cost more");

        uint256 foundrySaving = gasBaseline - gasCurrent;
        uint256 rootstockSaving = baselineMapWrites * (200 + 5_000);
        console2.log("Foundry gas current 10-row _batchRetrieveStablecoin:", gasCurrent);
        console2.log("Foundry gas baseline with idle ledger:", gasBaseline);
        console2.log("Foundry saving (warm Cancun debit):", foundrySaving);
        console2.log("Rootstock ledger saving (writes * 5200):", rootstockSaving);
        assertEq(rootstockSaving, ROOTSTOCK_LEDGER_SAVING_10_ROWS);
        // Warm Foundry RESET ≈ 100/row plus SLOAD/compute; pin the measured Cancun delta.
        assertApproxEqAbs(foundrySaving, 9_000, 4_000, "idle-ledger Foundry saving drifted");
    }

    function _mappingValueWrites(Vm.AccountAccess[] memory accesses, address target) private pure returns (uint256 n) {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != target) continue;
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory sa = accesses[i].storageAccesses[j];
                if (!sa.isWrite) continue;
                if (uint256(sa.slot) > 100) ++n;
            }
        }
    }
}

contract IdleGasHarness is IdleErc20Handler {
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    ) IdleErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, initialOwner) {}

    function exposedBatchRetrieve(address[] calldata users, uint256[] calldata purchaseAmounts)
        external
        returns (uint256)
    {
        return _batchRetrieveStablecoin(users, purchaseAmounts);
    }
}

/**
 * @dev Pre-removal idle funding path only: deposit books `s_idleBalances`, batch debit reads and
 *      writes that map. Withdraw clamp is omitted — this harness exists to price batch funding.
 */
contract IdleLedgerBaselineHarness is TokenHandler {
    mapping(address user => uint256 balance) internal s_idleBalances;

    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    ) TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, initialOwner) {}

    function _depositToken(address user, uint256 depositAmount) internal override {
        super._depositToken(user, depositAmount);
        s_idleBalances[user] += depositAmount;
    }

    function _batchRetrieveStablecoin(address[] calldata users, uint256[] calldata purchaseAmounts)
        internal
        override
        returns (uint256 totalWithdrawn)
    {
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 idleBalance = s_idleBalances[users[i]];
            require(amount <= idleBalance, "baseline underfunded");
            unchecked {
                s_idleBalances[users[i]] = idleBalance - amount;
            }
            totalWithdrawn += amount;
        }
    }

    function exposedBatchRetrieve(address[] calldata users, uint256[] calldata purchaseAmounts)
        external
        returns (uint256)
    {
        return _batchRetrieveStablecoin(users, purchaseAmounts);
    }
}
