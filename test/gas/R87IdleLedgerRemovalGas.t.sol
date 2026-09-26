// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IdleErc20Handler} from "src/idle/IdleErc20Handler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import "test/Constants.sol";

/**
 * @title R87IdleLedgerRemovalGas
 * @notice Proves the post-removal idle handler performs no per-user ledger SSTORE on deposit,
 *         withdraw, or batch funding, and prints Foundry gas for both profiles.
 * @dev Reproduce (default profile, then deploy):
 *
 *          forge test --match-path test/gas/R87IdleLedgerRemovalGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R87IdleLedgerRemovalGas.t.sol -vv
 *
 *      Rootstock conversion for the removed work (one cold SLOAD + one RESET per row / user op):
 *      200 + 5_000 = 5_200 gas. A 10-row idle batch therefore saves about 52k Rootstock gas on the
 *      ledger alone; the R87 verdict measured ≈5.75k / row including read paths around the map.
 */
contract R87IdleLedgerRemovalGasTest is Test {
    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant ROWS = 10;

    address internal constant DCA = address(0xDCA);
    MockStablecoin internal token;
    IdleGasHarness internal harness;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
        harness = new IdleGasHarness(DCA, address(token), address(0xFEE), feeSettings, address(this));
    }

    function test_gas_idleDepositWithdrawHaveNoPerUserLedgerWrites() public {
        address user = address(0xA11CE);
        token.mint(user, DEPOSIT * 2);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);

        vm.startStateDiffRecording();
        vm.prank(DCA);
        harness.depositToken(user, DEPOSIT);
        Vm.AccountAccess[] memory depositAccesses = vm.stopAndReturnStateDiff();
        assertEq(_mappingValueWrites(depositAccesses, address(harness)), 0, "deposit wrote a mapping slot");

        vm.startStateDiffRecording();
        vm.prank(DCA);
        harness.withdrawToken(user, DEPOSIT / 2);
        Vm.AccountAccess[] memory withdrawAccesses = vm.stopAndReturnStateDiff();
        assertEq(_mappingValueWrites(withdrawAccesses, address(harness)), 0, "withdraw wrote a mapping slot");
    }

    function test_gas_idleBatchFundingHasNoPerUserLedgerWrites() public {
        address[] memory users = new address[](ROWS);
        uint256[] memory amounts = new uint256[](ROWS);
        for (uint256 i; i < ROWS; ++i) {
            users[i] = address(uint160(0x1000 + i));
            amounts[i] = DEPOSIT;
            token.mint(users[i], DEPOSIT);
            vm.prank(users[i]);
            token.approve(address(harness), type(uint256).max);
            vm.prank(DCA);
            harness.depositToken(users[i], DEPOSIT);
        }

        vm.startStateDiffRecording();
        uint256 gasBefore = gasleft();
        uint256 total = harness.exposedBatchRetrieve(users, amounts);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertEq(total, DEPOSIT * ROWS);
        assertEq(_mappingValueWrites(accesses, address(harness)), 0, "batch funding wrote a mapping slot");
        console2.log("Foundry gas idle 10-row _batchRetrieveStablecoin:", gasUsed);
        console2.log("Rootstock ledger saving estimate (10 * 5200):", uint256(10 * 5200));
    }

    /// @dev Count SSTORE to mapping-value slots (keccak-derived keys). Immutables and non-mapping
    ///      layout slots sit below the free-slot threshold used by the Solidity compiler.
    function _mappingValueWrites(Vm.AccountAccess[] memory accesses, address target) private pure returns (uint256 n) {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != target) continue;
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory sa = accesses[i].storageAccesses[j];
                if (!sa.isWrite) continue;
                // Mapping slots are hashed; plain layout slots are small integers.
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
