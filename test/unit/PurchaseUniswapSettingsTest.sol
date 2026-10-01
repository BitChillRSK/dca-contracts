// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {PurchaseUniswap} from "../../src/PurchaseUniswap.sol";
import {PurchaseFees} from "../../src/PurchaseFees.sol";
import {DcaManagerAccessControl} from "../../src/DcaManagerAccessControl.sol";
import {IdleHandlerDex} from "../../src/idle/IdleHandlerDex.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseFees} from "../../src/interfaces/IPurchaseFees.sol";
import {ICoinPairPrice} from "../../src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "../../src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "../../src/interfaces/IUniswapV3SwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMocOracle} from "../mocks/MockMocOracle.sol";
import "../Constants.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract PurchaseUniswapSettingsTest is DcaDappTest {
    /// @dev Idle Dex: Ownable (0–1), fees (2–3), accumulated rBTC (4), oracle+live floor (5),
    ///      safety floor (6). Lending Dex inserts `s_shares` at 4 and shifts the Uniswap words up by one.
    uint256 private constant IDLE_ORACLE_SLOT = 5;
    uint256 private constant IDLE_SAFETY_SLOT = 6;
    uint256 private constant LENDING_ORACLE_SLOT = 6;
    uint256 private constant LENDING_SAFETY_SLOT = 7;

    event PurchaseUniswap__AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap__OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event PurchaseUniswap__NewPathSet(address[] intermediateTokens, uint24[] poolFeeRates, bytes newPath);

    function setUp() public override {
        super.setUp();
    }

    ///////////////////////////////
    /// Slippage Settings Tests ///
    ///////////////////////////////

    /// @dev The MoC oracle and the live 1e18-scaled floor share one word; the safety floor is alone
    ///      in the next. Slot numbers after that pair are unchanged. See `IDLE_*` / `LENDING_*`.
    function testSlippagePercentsShareOneSlot() public onlyDexSwaps {
        uint256 percent = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent();
        uint256 safetyCheck = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck();
        address oracle = address(IPurchaseUniswap(address(stablecoinHandler)).getMocOracle());
        uint256 oracleSlot = isLendingLane ? LENDING_ORACLE_SLOT : IDLE_ORACLE_SLOT;
        uint256 safetySlot = isLendingLane ? LENDING_SAFETY_SLOT : IDLE_SAFETY_SLOT;

        uint256 packedOracle = uint256(vm.load(address(stablecoinHandler), bytes32(oracleSlot)));
        assertEq(address(uint160(packedOracle)), oracle, "oracle is not the low 160 bits of its slot");
        assertEq(uint64(packedOracle >> 160), percent, "the swap-time floor is not packed beside the oracle");

        uint256 packedSafety = uint256(vm.load(address(stablecoinHandler), bytes32(safetySlot)));
        assertEq(uint64(packedSafety), safetyCheck, "the safety check is not the low half of the next slot");
        assertEq(packedSafety >> 64, 0, "the safety slot should hold only the uint64 floor");

        // A write through the setter lands in the same word and preserves the packed neighbor.
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.98 ether);

        packedOracle = uint256(vm.load(address(stablecoinHandler), bytes32(oracleSlot)));
        assertEq(address(uint160(packedOracle)), oracle, "the percent setter disturbed the oracle");
        assertEq(uint64(packedOracle >> 160), 0.98 ether, "the setter did not write the packed floor");
        packedSafety = uint256(vm.load(address(stablecoinHandler), bytes32(safetySlot)));
        assertEq(uint64(packedSafety), safetyCheck, "the percent setter disturbed the safety check");
    }

    function testSlippageSettings() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 initialPercent = dex.getAmountOutMinimumPercent();
        uint256 initialSafetyCheck = dex.getAmountOutMinimumSafetyCheck();

        assertEq(initialPercent, DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT, "Wrong initial swap-time floor");
        assertEq(initialSafetyCheck, DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK, "Wrong initial safety check");
        assertGe(initialPercent, initialSafetyCheck, "the deploy defaults must satisfy the band");

        uint256 newPercent = DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT * 999 / 1000;
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap__AmountOutMinimumPercentUpdated(initialPercent, newPercent);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(newPercent);
        assertEq(dex.getAmountOutMinimumPercent(), newPercent, "Swap-time floor should be updated");

        uint256 newSafetyCheck = DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK * 999 / 1000;
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated(initialSafetyCheck, newSafetyCheck);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(newSafetyCheck);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), newSafetyCheck, "Safety check should be updated");
    }

    function testSetAmountOutMinimumPercentRevertsIfTooHigh() public onlyDexSwaps {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooHigh.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(1.01e18);
    }

    /// @dev The wall. One owner transaction cannot widen the live floor past what governance pre-approved.
    function testSetAmountOutMinimumPercentRevertsIfBelowSafetyCheck() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 safetyCheck = dex.getAmountOutMinimumSafetyCheck();
        uint256 percentBefore = dex.getAmountOutMinimumPercent();

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(safetyCheck - 1);

        assertEq(dex.getAmountOutMinimumPercent(), percentBefore, "the floor must be unchanged on revert");
    }

    function testSetAmountOutMinimumSafetyCheckRevertsIfAboveCurrentPercent() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 percent = dex.getAmountOutMinimumPercent();
        uint256 safetyBefore = dex.getAmountOutMinimumSafetyCheck();

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(percent + 1);

        assertEq(dex.getAmountOutMinimumSafetyCheck(), safetyBefore, "Safety check must be unchanged on revert");
        assertEq(dex.getAmountOutMinimumPercent(), percent, "Floor must be unchanged on revert");
    }

    /// @dev Widening the live floor below the wall is deliberately two owner transactions, in this order.
    function testWideningBelowTheWallTakesTwoTransactions() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 target = DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK - 0.01 ether;

        // One transaction cannot get there.
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(target);

        // Lowering the wall first does.
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(target);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(target);

        assertEq(dex.getAmountOutMinimumPercent(), target);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), target);
    }

    function testSetAmountOutMinimumSafetyCheckRevertsIfTooHigh() public onlyDexSwaps {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(1.01e18);
    }

    function testSetSlippageSettingsBothAtHundredPercent() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 percentBefore = dex.getAmountOutMinimumPercent();
        uint256 safetyBefore = dex.getAmountOutMinimumSafetyCheck();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap__AmountOutMinimumPercentUpdated(percentBefore, 1 ether);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(1 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated(safetyBefore, 1 ether);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(1 ether);

        assertEq(dex.getAmountOutMinimumPercent(), 1 ether);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), 1 ether);
    }

    function testSetSlippageSettingsRaiseThenLower() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 initialPercent = dex.getAmountOutMinimumPercent();
        uint256 initialSafety = dex.getAmountOutMinimumSafetyCheck();
        uint256 raisedPercent = (initialPercent + 1 ether) / 2;
        uint256 raisedSafety = (initialSafety + raisedPercent) / 2;

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap__AmountOutMinimumPercentUpdated(initialPercent, raisedPercent);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(raisedPercent);
        assertEq(dex.getAmountOutMinimumPercent(), raisedPercent);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated(initialSafety, raisedSafety);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(raisedSafety);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), raisedSafety);

        uint256 loweredSafety = raisedSafety / 2;
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated(raisedSafety, loweredSafety);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(loweredSafety);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), loweredSafety);
    }

    function testOnlyOwnerCanSetSlippageSettings() public onlyDexSwaps {
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.98e18);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(0.95e18);
    }

    ////////////////////////////
    /// Oracle Update Tests ////
    ////////////////////////////

    function testUpdateOracle() public onlyDexSwaps {
        // Create a new mock oracle
        MockMocOracle newMocOracle = new MockMocOracle();

        // Store the current oracle for comparison
        ICoinPairPrice currentOracle = IPurchaseUniswap(address(stablecoinHandler)).getMocOracle();
        address oldOracleAddress = address(currentOracle);

        // Expect the event with the correct parameters
        vm.expectEmit(true, true, false, false);
        emit PurchaseUniswap__OracleUpdated(oldOracleAddress, address(newMocOracle));

        // Update the oracle
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setMocOracle(address(newMocOracle));

        // Verify the oracle was updated
        address updatedOracleAddress = address(IPurchaseUniswap(address(stablecoinHandler)).getMocOracle());
        assertEq(updatedOracleAddress, address(newMocOracle), "Oracle address should be updated");
        assertNotEq(updatedOracleAddress, oldOracleAddress, "Oracle address should be different from the old one");
    }

    function testUpdateOracleRevertsIfZeroAddress() public onlyDexSwaps {
        // Try to update with zero address
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__InvalidOracleAddress.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setMocOracle(address(0));
    }

    function testConstructorRevertsIfOracleIsZeroAddress() public onlyDexSwaps {
        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrbtc: IWRBTC(address(wrbtc)),
            swapRouter: IUniswapV3SwapRouter(
                address(PurchaseUniswap(payable(address(stablecoinHandler))).i_swapRouter())
            ),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(0))
        });
        IPurchaseFees.FeeSettings memory feeSettings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
        });

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__InvalidOracleAddress.selector);
        new IdleHandlerDex(
            address(this),
            address(stablecoin),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            OWNER
        );
    }

    function testOnlyOwnerCanUpdateOracle() public onlyDexSwaps {
        // Create a new mock oracle
        MockMocOracle newMocOracle = new MockMocOracle();

        // Try to update oracle as non-owner
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setMocOracle(address(newMocOracle));
    }

    ////////////////////////////
    /// Price Validation Tests //
    ////////////////////////////

    function testOutdatedPriceRevertsSwap() public onlyDexSwaps {
        // Setup: First perform the necessary setup for the test
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        vm.stopPrank();

        // Create a mock oracle that returns invalid prices
        MockMocOracle invalidOracle = new MockMocOracle();
        invalidOracle.setInvalidPrice();

        // Update the oracle to use our invalid one
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setMocOracle(address(invalidOracle));

        // Try to make a purchase, which should revert due to invalid price
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector);
        buyRbtcOne(scheduleId);
    }

    ////////////////////////////
    /// Purchase Path Tests ////
    ////////////////////////////

    function testSetPurchasePath() public onlyDexSwaps {
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = makeAddr("newIntermediateToken");

        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 100; // 0.01%
        poolFeeRates[1] = 300; // 0.03%

        bytes memory oldPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        bytes memory expectedPath = _encodeSwapPath(intermediateTokens, poolFeeRates);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(intermediateTokens, poolFeeRates, true);

        vm.expectEmit(false, false, false, true);
        emit PurchaseUniswap__NewPathSet(intermediateTokens, poolFeeRates, expectedPath);

        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);

        bytes memory newPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertNotEq(keccak256(newPath), keccak256(oldPath), "Path should be updated");
        assertEq(newPath, expectedPath);
    }

    function testSetPurchasePathRevertsWithWrongArrayLengths() public onlyDexSwaps {
        // Create test data with mismatched lengths
        address[] memory intermediateTokens = new address[](2);
        intermediateTokens[0] = makeAddr("token1");
        intermediateTokens[1] = makeAddr("token2");

        uint24[] memory poolFeeRates = new uint24[](2); // Should be 3 for 2 intermediate tokens
        poolFeeRates[0] = 100;
        poolFeeRates[1] = 300;

        // Try to set the path with mismatched arrays
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__WrongNumberOfTokensOrFeeRates.selector,
                intermediateTokens.length,
                poolFeeRates.length
            )
        );
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);
    }

    function testUnauthorizedCannotSetPurchasePath() public onlyDexSwaps {
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = makeAddr("token");

        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 100;
        poolFeeRates[1] = 300;

        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(intermediateTokens, poolFeeRates, true);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__UnauthorizedPurchasePathSetter.selector, USER)
        );
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);
    }

    function testSwapPathStartsWithPurchaseToken() public onlyDexSwaps {
        bytes memory initialPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertEq(_firstTokenInPath(initialPath), address(stablecoin), "initial path must start with i_stablecoin");

        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = makeAddr("r31Intermediate");
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 100;
        poolFeeRates[1] = 300;

        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(intermediateTokens, poolFeeRates, true);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);

        bytes memory updatedPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertEq(_firstTokenInPath(updatedPath), address(stablecoin), "updated path must start with i_stablecoin");
    }

    function _firstTokenInPath(bytes memory path) private pure returns (address token) {
        require(path.length >= 20, "path too short");
        uint256 packed;
        for (uint256 i; i < 20; ++i) {
            packed = (packed << 8) | uint8(path[i]);
        }
        return address(uint160(packed));
    }

    function _encodeSwapPath(address[] memory intermediateTokens, uint24[] memory poolFeeRates)
        private
        view
        returns (bytes memory path)
    {
        path = abi.encodePacked(address(stablecoin));
        for (uint256 i; i < intermediateTokens.length; ++i) {
            path = abi.encodePacked(path, poolFeeRates[i], intermediateTokens[i]);
        }
        path = abi.encodePacked(path, poolFeeRates[poolFeeRates.length - 1], address(wrbtc));
    }
}
