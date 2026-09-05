// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {PurchaseUniswap} from "../../src/PurchaseUniswap.sol";
import {FeeHandler} from "../../src/FeeHandler.sol";
import {DcaManagerAccessControl} from "../../src/DcaManagerAccessControl.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {ICoinPairPrice} from "../../src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "../../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMocOracle} from "../mocks/MockMocOracle.sol";
import "../Constants.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract PurchaseUniswapSettingsTest is DcaDappTest {
    uint256 private constant SLIPPAGE_SLOT = 7;

    event PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event PurchaseUniswap_NewPathSet(address[] intermediateTokens, uint24[] poolFeeRates, bytes newPath);

    function setUp() public override {
        super.setUp();
    }

    ///////////////////////////////
    /// Slippage Settings Tests ///
    ///////////////////////////////

    /// @dev The two 1e18-scaled fractions are uint128s in one slot. The Dex handler's storage is
    ///      Ownable2Step (0, 1), the fee word and bounds (2, 3), shares (4), accumulated rBTC (5),
    ///      the oracle (6), then this pair.
    function testSlippagePercentsShareOneSlot() public onlyDexSwaps {
        uint256 percent = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent();
        uint256 safetyCheck = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck();

        uint256 packed = uint256(vm.load(address(stablecoinHandler), bytes32(SLIPPAGE_SLOT)));
        assertEq(uint128(packed), percent, "the swap-time floor is not the low half of the slot");
        assertEq(uint128(packed >> 128), safetyCheck, "the safety check is not the high half of the slot");

        // A write through the setter lands in the same word.
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.98 ether);

        packed = uint256(vm.load(address(stablecoinHandler), bytes32(SLIPPAGE_SLOT)));
        assertEq(uint128(packed), 0.98 ether, "the setter did not write the low half");
        assertEq(uint128(packed >> 128), safetyCheck, "the setter disturbed the safety check");
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
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(initialPercent, newPercent);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(newPercent);
        assertEq(dex.getAmountOutMinimumPercent(), newPercent, "Swap-time floor should be updated");

        uint256 newSafetyCheck = DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK * 999 / 1000;
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(initialSafetyCheck, newSafetyCheck);
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
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(percentBefore, 1 ether);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(1 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 1 ether);
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
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(initialPercent, raisedPercent);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(raisedPercent);
        assertEq(dex.getAmountOutMinimumPercent(), raisedPercent);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(initialSafety, raisedSafety);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(raisedSafety);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), raisedSafety);

        uint256 loweredSafety = raisedSafety / 2;
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(raisedSafety, loweredSafety);
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
        emit PurchaseUniswap_OracleUpdated(oldOracleAddress, address(newMocOracle));

        // Update the oracle
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(newMocOracle));
        
        // Verify the oracle was updated
        address updatedOracleAddress = address(IPurchaseUniswap(address(stablecoinHandler)).getMocOracle());
        assertEq(updatedOracleAddress, address(newMocOracle), "Oracle address should be updated");
        assertNotEq(updatedOracleAddress, oldOracleAddress, "Oracle address should be different from the old one");
    }
    
    function testUpdateOracleRevertsIfZeroAddress() public onlyDexSwaps {
        // Try to update with zero address
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__InvalidOracleAddress.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(0));
    }
    
    function testOnlyOwnerCanUpdateOracle() public onlyDexSwaps {
        // Create a new mock oracle
        MockMocOracle newMocOracle = new MockMocOracle();
        
        // Try to update oracle as non-owner
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(newMocOracle));
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
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(invalidOracle));
        
        
        // Try to make a purchase, which should revert due to invalid price. Built before arming the
        // cheatcode: buyRbtcOne's own getDcaSchedule read would otherwise consume this expectRevert
        // before the purchase call it is meant for.
        IDcaManager.Batch memory batch = currentBatch(scheduleId);
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
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
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(
            intermediateTokens, poolFeeRates, true
        );

        vm.expectEmit(false, false, false, true);
        emit PurchaseUniswap_NewPathSet(intermediateTokens, poolFeeRates, expectedPath);

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
        vm.expectRevert(abi.encodeWithSelector(
            IPurchaseUniswap.PurchaseUniswap__WrongNumberOfTokensOrFeeRates.selector, 
            intermediateTokens.length, 
            poolFeeRates.length
        ));
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
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(
            intermediateTokens, poolFeeRates, true
        );
        
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__UnauthorizedPurchasePathSetter.selector, USER
            )
        );
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);
    }

    function testSwapPathStartsWithPurchaseToken() public onlyDexSwaps {
        bytes memory initialPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertEq(_firstTokenInPath(initialPath), address(stablecoin), "initial path must start with _purchaseToken()");

        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = makeAddr("r31Intermediate");
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 100;
        poolFeeRates[1] = 300;

        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(
            intermediateTokens, poolFeeRates, true
        );
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);

        bytes memory updatedPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertEq(_firstTokenInPath(updatedPath), address(stablecoin), "updated path must start with _purchaseToken()");
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
        path = abi.encodePacked(path, poolFeeRates[poolFeeRates.length - 1], address(wrBtcToken));
    }
}

// ZeroTokenPurchaseUniswap and its test moved to ZeroTokenPurchaseUniswapTest.sol (R60): that
// contract's constructor is deliberately always-reverting, which trips a known solc/via_ir limitation
// (see that file's doc comment) and must be excluded from IR compilation on its own.
