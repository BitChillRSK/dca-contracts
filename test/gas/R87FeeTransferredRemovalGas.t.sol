// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {FeeHandler} from "src/FeeHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title R87FeeTransferredRemovalGas
 * @notice Prices `_transferFee` without the custom fee event against a baseline that still emits it.
 * @dev Reproduce:
 *
 *          forge test --match-path test/gas/R87FeeTransferredRemovalGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R87FeeTransferredRemovalGas.t.sol -vv
 *
 *      Rootstock: dropping one `LOG3` with a data word is about 1,804 gas (R87 verdict).
 */
contract R87FeeTransferredRemovalGasTest is Test {
    uint256 internal constant FEE = 1 ether;

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

        console2.log("Foundry gas current _transferFee:", gasCurrent);
        console2.log("Foundry gas baseline with FeeTransferred:", gasBaseline);
        console2.log("Foundry saving:", gasBaseline - gasCurrent);
        assertGt(gasBaseline, gasCurrent, "baseline without the custom event should be cheaper");
        // LOG3 ≈ 1.5–2k Foundry; absorb forge noise.
        assertApproxEqAbs(gasBaseline - gasCurrent, 1_800, 800, "saving drifted from LOG3 cost");
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

contract FeeTransferBaseline is FeeHandler {
    using SafeERC20 for IERC20;

    event FeeHandler__FeeTransferred(address indexed token, address indexed collector, uint256 amount);

    constructor(address feeCollector, FeeSettings memory feeSettings, address initialOwner)
        FeeHandler(feeCollector, feeSettings, initialOwner)
    {}

    function exposedTransferFee(IERC20 token, uint256 fee) external {
        if (fee == 0) return;
        address collector = this.getFeeCollectorAddress();
        token.safeTransfer(collector, fee);
        emit FeeHandler__FeeTransferred(address(token), collector, fee);
    }
}
