// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {FeeHandler} from "src/FeeHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title R87FeeTransferredRemovalGas
 * @notice Faithful old/new `_transferFee`: baseline mirrors the pre-removal body (direct
 *         `s_feeCollector` read + `safeTransfer` + `FeeTransferred`); current is production.
 * @dev Reproduce:
 *
 *          forge test --match-path test/gas/R87FeeTransferredRemovalGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R87FeeTransferredRemovalGas.t.sol -vv
 *
 *      Foundry pin ≈ 1,800–2,500 for the dropped `LOG3` (one data word). Rootstock is the same
 *      log schedule for that opcode class; convert only if you re-price the transfer itself.
 */
contract R87FeeTransferredRemovalGasTest is Test {
    uint256 internal constant FEE = 1 ether;
    /// @dev Foundry regression pin for the LOG3 delta; ±500 absorbs forge noise.
    uint256 internal constant EXPECTED_FOUNDRY_SAVING = 2_000;

    MockStablecoin internal token;
    FeeTransferCurrent internal current;
    FeeTransferBaseline internal baseline;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: 100,
            maxFeeRate: 100,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        current = new FeeTransferCurrent(address(0xFEE), feeSettings, address(this));
        baseline = new FeeTransferBaseline(address(0xFEE), feeSettings, address(this));
        token.mint(address(current), FEE * 10);
        token.mint(address(baseline), FEE * 10);
    }

    function test_gas_droppingFeeTransferredSavesLogCost() public {
        uint256 snap = vm.snapshot();

        uint256 gasCurrent = gasleft();
        current.exposedTransferFee(token, FEE);
        gasCurrent = gasCurrent - gasleft();

        vm.revertTo(snap);

        uint256 gasBaseline = gasleft();
        baseline.exposedTransferFee(token, FEE);
        gasBaseline = gasBaseline - gasleft();

        uint256 saving = gasBaseline - gasCurrent;
        console2.log("Foundry gas current _transferFee:", gasCurrent);
        console2.log("Foundry gas baseline with FeeTransferred:", gasBaseline);
        console2.log("Foundry saving:", saving);
        assertGt(saving, 1_000, "saving smaller than a LOG3");
        assertLt(saving, 4_000, "saving larger than a LOG3; baseline probably diverged");
        assertApproxEqAbs(saving, EXPECTED_FOUNDRY_SAVING, 500, "fee-event Foundry saving drifted");
    }
}

contract FeeTransferCurrent is FeeHandler {
    constructor(address feeCollector, FeeSettings memory feeSettings, address initialOwner)
        FeeHandler(feeCollector, feeSettings, initialOwner)
    {}

    function exposedTransferFee(IERC20 token, uint256 fee) external {
        _transferFee(token, fee);
    }
}

/// @dev Pre-removal `_transferFee` body: direct storage read, transfer, custom event.
contract FeeTransferBaseline is FeeHandler {
    using SafeERC20 for IERC20;

    event FeeHandler__FeeTransferred(address indexed token, address indexed collector, uint256 amount);

    constructor(address feeCollector, FeeSettings memory feeSettings, address initialOwner)
        FeeHandler(feeCollector, feeSettings, initialOwner)
    {}

    function exposedTransferFee(IERC20 token, uint256 fee) external {
        if (fee == 0) return;
        address collector = s_feeCollector;
        token.safeTransfer(collector, fee);
        emit FeeHandler__FeeTransferred(address(token), collector, fee);
    }
}
